//! Outbound JSON-RPC clients.

const std = @import("std");
const codec = @import("codec.zig");
const serde = @import("serde.zig");
const types = @import("types.zig");

pub const ClientError = error{
    InvalidResponseId,
    UnexpectedNotificationResponse,
    EmptyBatchResponse,
    DuplicateRequestId,
    DuplicateResponseId,
};

pub const Transport = struct {
    context: ?*anyopaque = null,
    callFn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,
    notifyFn: *const fn (?*anyopaque, []const u8) anyerror!void,
};

pub fn CallResult(comptime T: type) type {
    return union(enum) {
        success: T,
        rpc_error: RemoteError,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .rpc_error => |*err| err.deinit(allocator),
                else => {},
            }
        }
    };
}

pub const RemoteError = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,

    pub fn deinit(self: *RemoteError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.data) |*data| codec.deinitValue(allocator, data);
        self.* = undefined;
    }
};

pub const BatchResponse = struct {
    id: types.Id,
    response: types.Response,
};

pub const StartedCall = struct {
    id: i64,
    request_bytes: []u8,
};

pub const StartOptions = struct {
    now_ms: u64 = 0,
    timeout_ms: ?u64 = null,
};

pub const AsyncCompletion = union(enum) {
    response: types.Response,
    cancelled,
    timed_out,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .response => |*response| deinitResponse(allocator, response),
            else => {},
        }
    }
};

pub const AsyncClient = struct {
    allocator: std.mem.Allocator,
    next_id: std.atomic.Value(i64),
    pending: std.AutoHashMap(i64, PendingCall),
    completed: std.AutoHashMap(i64, AsyncCompletion),
    mutex: std.Thread.Mutex,

    const Self = @This();

    const PendingCall = struct {
        deadline_ms: ?u64,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .next_id = std.atomic.Value(i64).init(1),
            .pending = std.AutoHashMap(i64, PendingCall).init(allocator),
            .completed = std.AutoHashMap(i64, AsyncCompletion).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.completed.valueIterator();
        while (iter.next()) |completion| {
            completion.deinit(self.allocator);
        }
        self.completed.deinit();
        self.pending.deinit();
    }

    pub fn startCall(
        self: *Self,
        allocator: std.mem.Allocator,
        comptime Params: type,
        method: []const u8,
        params: Params,
        options: StartOptions,
    ) !StartedCall {
        const id = self.next_id.fetchAdd(1, .monotonic);
        var params_value = try encodeClientParams(allocator, Params, params);
        defer if (params_value) |*value| codec.deinitValue(allocator, value);

        const request = types.Request{
            .method = method,
            .params = params_value,
            .id = .{ .number = id },
        };
        const request_bytes = try serde.encodeRequestAlloc(allocator, request);
        errdefer allocator.free(request_bytes);

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pending.put(id, .{
            .deadline_ms = if (options.timeout_ms) |timeout| options.now_ms + timeout else null,
        });

        return .{
            .id = id,
            .request_bytes = request_bytes,
        };
    }

    pub fn acceptResponseBytes(self: *Self, allocator: std.mem.Allocator, bytes: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
            return error.InvalidJson;
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .array => |array| {
                if (array.items.len == 0) return error.InvalidResponse;
                var seen = std.AutoHashMap(i64, void).init(allocator);
                defer seen.deinit();

                for (array.items) |item| {
                    const response = try serde.parseResponseValue(item);
                    const id = responseNumericId(response) orelse return error.InvalidResponseId;
                    if (seen.contains(id)) return error.DuplicateResponseId;
                    try seen.put(id, {});
                    try self.completePending(allocator, id, response);
                }
            },
            else => {
                const response = try serde.parseResponseValue(parsed.value);
                const id = responseNumericId(response) orelse return error.InvalidResponseId;
                try self.completePending(allocator, id, response);
            },
        }
    }

    pub fn cancel(self: *Self, id: i64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.pending.remove(id)) return false;
        try self.storeCompletionLocked(id, .cancelled);
        return true;
    }

    pub fn expireTimeouts(self: *Self, now_ms: u64) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var expired = std.ArrayList(i64){};
        defer expired.deinit(self.allocator);

        var iter = self.pending.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.deadline_ms) |deadline| {
                if (deadline <= now_ms) {
                    try expired.append(self.allocator, entry.key_ptr.*);
                }
            }
        }

        for (expired.items) |id| {
            _ = self.pending.remove(id);
            try self.storeCompletionLocked(id, .timed_out);
        }

        return expired.items.len;
    }

    pub fn takeCompletion(self: *Self, id: i64) ?AsyncCompletion {
        self.mutex.lock();
        defer self.mutex.unlock();
        const removed = self.completed.fetchRemove(id) orelse return null;
        return removed.value;
    }

    pub fn hasPending(self: *Self, id: i64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending.contains(id);
    }

    fn completePending(self: *Self, allocator: std.mem.Allocator, id: i64, response: types.Response) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.pending.remove(id)) return error.InvalidResponseId;
        try self.storeCompletionLocked(id, .{ .response = try cloneResponse(allocator, response) });
    }

    fn storeCompletionLocked(self: *Self, id: i64, completion: AsyncCompletion) !void {
        if (self.completed.contains(id)) return error.DuplicateResponseId;
        try self.completed.put(id, completion);
    }
};

pub const Client = struct {
    transport: Transport,
    next_id: std.atomic.Value(i64),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(transport: Transport) Self {
        return .{
            .transport = transport,
            .next_id = std.atomic.Value(i64).init(1),
            .mutex = .{},
        };
    }

    pub fn call(
        self: *Self,
        allocator: std.mem.Allocator,
        comptime Params: type,
        comptime Result: type,
        method: []const u8,
        params: Params,
    ) anyerror!CallResult(Result) {
        const request_id: types.Id = .{ .number = self.next_id.fetchAdd(1, .monotonic) };
        var params_value = try encodeClientParams(allocator, Params, params);
        defer if (params_value) |*value| codec.deinitValue(allocator, value);

        const request = types.Request{
            .method = method,
            .params = params_value,
            .id = request_id,
        };

        const request_bytes = try serde.encodeRequestAlloc(allocator, request);
        defer allocator.free(request_bytes);

        self.mutex.lock();
        const response_bytes = self.transport.callFn(self.transport.context, allocator, request_bytes) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        defer allocator.free(response_bytes);

        var parsed = try serde.parseResponse(allocator, response_bytes);
        defer parsed.deinit();

        switch (parsed.response) {
            .success => |success| {
                if (!success.id.eql(request_id)) return error.InvalidResponseId;
                return .{ .success = try codec.decodeResult(Result, success.result) };
            },
            .err => |failure| {
                if (!failure.id.eql(request_id)) return error.InvalidResponseId;
                return .{ .rpc_error = try cloneRemoteError(allocator, failure.err) };
            },
        }
    }

    pub fn notify(
        self: *Self,
        allocator: std.mem.Allocator,
        comptime Params: type,
        method: []const u8,
        params: Params,
    ) anyerror!void {
        var params_value = try encodeClientParams(allocator, Params, params);
        defer if (params_value) |*value| codec.deinitValue(allocator, value);

        const request = types.Request{
            .method = method,
            .params = params_value,
        };

        const request_bytes = try serde.encodeRequestAlloc(allocator, request);
        defer allocator.free(request_bytes);

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.transport.notifyFn(self.transport.context, request_bytes);
    }

    pub fn callBatch(
        self: *Self,
        allocator: std.mem.Allocator,
        requests: []const types.Request,
    ) anyerror![]BatchResponse {
        if (requests.len == 0) return error.InvalidRequest;
        try validateBatchRequests(allocator, requests);

        const request_bytes = try serde.encodeRequestBatchAlloc(allocator, requests);
        defer allocator.free(request_bytes);

        self.mutex.lock();
        const response_bytes = self.transport.callFn(self.transport.context, allocator, request_bytes) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        defer allocator.free(response_bytes);

        if (response_bytes.len == 0) return error.EmptyBatchResponse;

        var parsed = try serde.parseResponseBatch(allocator, response_bytes);
        defer parsed.deinit();

        var initialized: usize = 0;
        const matched = try allocator.alloc(BatchResponse, parsed.responses.len);
        errdefer {
            for (matched[0..initialized]) |*item| {
                deinitResponse(allocator, &item.response);
            }
            allocator.free(matched);
        }

        var seen = std.StringHashMap(void).init(allocator);
        defer {
            var iter = seen.keyIterator();
            while (iter.next()) |key| allocator.free(key.*);
            seen.deinit();
        }

        for (parsed.responses, 0..) |response, index| {
            const response_id = switch (response) {
                .success => |success| success.id,
                .err => |failure| failure.id,
            };

            const response_key = try batchIdKey(allocator, response_id);
            defer allocator.free(response_key);
            if (seen.contains(response_key)) return error.DuplicateResponseId;
            try seen.put(try allocator.dupe(u8, response_key), {});

            if (!containsRequestId(requests, response_id)) return error.InvalidResponseId;
            matched[index] = .{
                .id = response_id,
                .response = try cloneResponse(allocator, response),
            };
            initialized += 1;
        }

        return matched;
    }

    pub fn notifyBatch(
        self: *Self,
        allocator: std.mem.Allocator,
        requests: []const types.Request,
    ) anyerror!void {
        if (requests.len == 0) return error.InvalidRequest;

        for (requests) |request| {
            if (!request.isNotification()) return error.InvalidRequest;
            try serde.validateRequest(request);
        }

        const request_bytes = try serde.encodeRequestBatchAlloc(allocator, requests);
        defer allocator.free(request_bytes);

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.transport.notifyFn(self.transport.context, request_bytes);
    }
};

fn cloneRemoteError(allocator: std.mem.Allocator, err: types.ErrorObject) !RemoteError {
    return .{
        .code = err.code,
        .message = try allocator.dupe(u8, err.message),
        .data = if (err.data) |data| try codec.cloneValue(allocator, data) else null,
    };
}

fn encodeClientParams(allocator: std.mem.Allocator, comptime Params: type, params: Params) !?std.json.Value {
    if (Params == void) return null;
    return try codec.encodeResult(allocator, params);
}

fn validateBatchRequests(allocator: std.mem.Allocator, requests: []const types.Request) !void {
    var ids = std.StringHashMap(void).init(allocator);
    defer {
        var iter = ids.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        ids.deinit();
    }

    for (requests) |request| {
        try serde.validateRequest(request);
        const request_id = request.id orelse return error.InvalidRequest;
        const key = try batchIdKey(allocator, request_id);
        defer allocator.free(key);
        if (ids.contains(key)) return error.DuplicateRequestId;
        try ids.put(try allocator.dupe(u8, key), {});
    }
}

fn responseNumericId(response: types.Response) ?i64 {
    const id = switch (response) {
        .success => |success| success.id,
        .err => |failure| failure.id,
    };

    return id.asExactInteger();
}

fn containsRequestId(requests: []const types.Request, response_id: types.Id) bool {
    for (requests) |request| {
        if (request.id) |request_id| {
            if (request_id.eql(response_id)) return true;
        }
    }
    return false;
}

fn cloneResponse(allocator: std.mem.Allocator, response: types.Response) !types.Response {
    return switch (response) {
        .success => |success| .{
            .success = .{
                .jsonrpc = success.jsonrpc,
                .result = try codec.cloneValue(allocator, success.result),
                .id = success.id,
            },
        },
        .err => |failure| .{
            .err = .{
                .jsonrpc = failure.jsonrpc,
                .err = .{
                    .code = failure.err.code,
                    .message = try allocator.dupe(u8, failure.err.message),
                    .data = if (failure.err.data) |data| try codec.cloneValue(allocator, data) else null,
                },
                .id = failure.id,
            },
        },
    };
}

fn deinitResponse(allocator: std.mem.Allocator, response: *types.Response) void {
    switch (response.*) {
        .success => |*success| codec.deinitValue(allocator, &success.result),
        .err => |*failure| {
            allocator.free(failure.err.message);
            if (failure.err.data) |*data| codec.deinitValue(allocator, data);
        },
    }
}

pub fn deinitBatchResponses(allocator: std.mem.Allocator, responses: []BatchResponse) void {
    for (responses) |*item| {
        deinitResponse(allocator, &item.response);
    }
    allocator.free(responses);
}

fn batchIdKey(allocator: std.mem.Allocator, id: types.Id) ![]u8 {
    if (id.asExactInteger()) |numeric| {
        return std.fmt.allocPrint(allocator, "n:{d}", .{numeric});
    }

    return switch (id) {
        .float => |numeric| std.fmt.allocPrint(allocator, "f:{d}", .{numeric}),
        .string => |string| std.fmt.allocPrint(allocator, "s:{s}", .{string}),
        .null => std.fmt.allocPrint(allocator, "null", .{}),
        .number => unreachable,
    };
}
