//! JSON-RPC 2.0 serialization and parsing.

const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{
    InvalidJson,
    InvalidVersion,
    InvalidRequest,
    InvalidResponse,
    InvalidId,
    InvalidMethod,
    InvalidParams,
    InvalidResult,
    InvalidError,
    UnsupportedBatch,
    OutOfMemory,
};

pub const ParsedRequest = struct {
    parsed: std.json.Parsed(std.json.Value),
    request: types.Request,

    pub fn deinit(self: *ParsedRequest) void {
        self.parsed.deinit();
    }
};

pub const ParsedResponse = struct {
    parsed: std.json.Parsed(std.json.Value),
    response: types.Response,

    pub fn deinit(self: *ParsedResponse) void {
        self.parsed.deinit();
    }
};

pub const ParsedResponseBatch = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(std.json.Value),
    responses: []types.Response,

    pub fn deinit(self: *ParsedResponseBatch) void {
        self.allocator.free(self.responses);
        self.parsed.deinit();
    }
};

pub fn encodeRequestBatchAlloc(allocator: std.mem.Allocator, requests: []const types.Request) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buffer.deinit(allocator);

    try writeRequestBatch(buffer.writer(allocator), requests);
    return buffer.toOwnedSlice(allocator);
}

pub fn encodeRequestAlloc(allocator: std.mem.Allocator, request: types.Request) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buffer.deinit(allocator);

    try writeRequest(buffer.writer(allocator), request);
    return buffer.toOwnedSlice(allocator);
}

pub fn encodeResponseBatchAlloc(allocator: std.mem.Allocator, responses: []const types.Response) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buffer.deinit(allocator);

    try writeResponseBatch(buffer.writer(allocator), responses);
    return buffer.toOwnedSlice(allocator);
}

pub fn encodeResponseAlloc(allocator: std.mem.Allocator, response: types.Response) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buffer.deinit(allocator);

    try writeResponse(buffer.writer(allocator), response);
    return buffer.toOwnedSlice(allocator);
}

pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) ParseError!ParsedRequest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return error.InvalidJson;
    };
    errdefer parsed.deinit();

    const request = try parseRequestValue(parsed.value);
    return .{
        .parsed = parsed,
        .request = request,
    };
}

pub fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!ParsedResponse {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return error.InvalidJson;
    };
    errdefer parsed.deinit();

    const response = try parseResponseValue(parsed.value);
    return .{
        .parsed = parsed,
        .response = response,
    };
}

pub fn parseResponseBatch(allocator: std.mem.Allocator, bytes: []const u8) ParseError!ParsedResponseBatch {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        return error.InvalidJson;
    };
    errdefer parsed.deinit();

    if (parsed.value != .array) return error.InvalidResponse;
    if (parsed.value.array.items.len == 0) return error.InvalidResponse;

    const responses = try allocator.alloc(types.Response, parsed.value.array.items.len);
    errdefer allocator.free(responses);

    for (parsed.value.array.items, 0..) |item, index| {
        responses[index] = try parseResponseValue(item);
    }

    return .{
        .allocator = allocator,
        .parsed = parsed,
        .responses = responses,
    };
}

pub fn writeRequest(writer: anytype, request: types.Request) !void {
    try validateRequest(request);

    try writer.writeByte('{');
    try writer.writeAll("\"jsonrpc\":");
    try writeString(writer, request.jsonrpc);
    try writer.writeAll(",\"method\":");
    try writeString(writer, request.method);

    if (request.params) |params| {
        try writer.writeAll(",\"params\":");
        try writeValue(writer, params);
    }

    if (request.id) |id| {
        try writer.writeAll(",\"id\":");
        try writeId(writer, id);
    }

    try writer.writeByte('}');
}

pub fn writeRequestBatch(writer: anytype, requests: []const types.Request) !void {
    if (requests.len == 0) return error.InvalidRequest;

    try writer.writeByte('[');
    for (requests, 0..) |request, index| {
        if (index != 0) try writer.writeByte(',');
        try writeRequest(writer, request);
    }
    try writer.writeByte(']');
}

pub fn writeResponse(writer: anytype, response: types.Response) !void {
    try validateResponse(response);

    try writer.writeByte('{');
    try writer.writeAll("\"jsonrpc\":");

    switch (response) {
        .success => |success| {
            try writeString(writer, success.jsonrpc);
            try writer.writeAll(",\"result\":");
            try writeValue(writer, success.result);
            try writer.writeAll(",\"id\":");
            try writeId(writer, success.id);
        },
        .err => |failure| {
            try writeString(writer, failure.jsonrpc);
            try writer.writeAll(",\"error\":");
            try writeError(writer, failure.err);
            try writer.writeAll(",\"id\":");
            try writeId(writer, failure.id);
        },
    }

    try writer.writeByte('}');
}

pub fn writeResponseBatch(writer: anytype, responses: []const types.Response) !void {
    if (responses.len == 0) return error.InvalidResponse;

    try writer.writeByte('[');
    for (responses, 0..) |response, index| {
        if (index != 0) try writer.writeByte(',');
        try writeResponse(writer, response);
    }
    try writer.writeByte(']');
}

pub fn parseRequestValue(value: std.json.Value) ParseError!types.Request {
    if (value == .array) return error.UnsupportedBatch;
    if (value != .object) return error.InvalidRequest;

    const object = value.object;
    try expectVersion(object);

    if (object.get("result") != null or object.get("error") != null) {
        return error.InvalidRequest;
    }

    const method_value = object.get("method") orelse return error.InvalidMethod;
    const method = switch (method_value) {
        .string => |actual| actual,
        else => return error.InvalidMethod,
    };
    try validateMethodName(method);

    const params = if (object.get("params")) |params_value| blk: {
        switch (params_value) {
            .object, .array => break :blk params_value,
            else => return error.InvalidRequest,
        }
    } else null;

    const id = if (object.get("id")) |id_value| try parseIdValue(id_value) else null;

    return .{
        .jsonrpc = VERSION_STR,
        .method = method,
        .params = params,
        .id = id,
    };
}

pub fn parseResponseValue(value: std.json.Value) ParseError!types.Response {
    if (value == .array) return error.UnsupportedBatch;
    if (value != .object) return error.InvalidResponse;

    const object = value.object;
    try expectVersion(object);

    const id = if (object.get("id")) |id_value|
        try parseIdValue(id_value)
    else
        return error.InvalidId;

    const has_result = object.get("result") != null;
    const has_error = object.get("error") != null;
    if (has_result == has_error) return error.InvalidResponse;

    if (has_result) {
        return .{
            .success = .{
                .result = object.get("result").?,
                .id = id,
            },
        };
    }

    return .{
        .err = .{
            .err = try parseErrorObject(object.get("error").?),
            .id = id,
        },
    };
}

pub fn parseIdValue(value: std.json.Value) ParseError!types.Id {
    return switch (value) {
        .string => |actual| .{ .string = actual },
        .integer => |actual| .{ .number = actual },
        .float => |actual| .{ .float = actual },
        .null => .null,
        else => error.InvalidId,
    };
}

pub fn validateRequest(request: types.Request) ParseError!void {
    if (!std.mem.eql(u8, request.jsonrpc, VERSION_STR)) return error.InvalidVersion;
    try validateMethodName(request.method);

    if (request.params) |params| {
        switch (params) {
            .object, .array => {},
            else => return error.InvalidRequest,
        }
    }
}

pub fn validateResponse(response: types.Response) ParseError!void {
    switch (response) {
        .success => |success| {
            if (!std.mem.eql(u8, success.jsonrpc, VERSION_STR)) return error.InvalidVersion;
        },
        .err => |failure| {
            if (!std.mem.eql(u8, failure.jsonrpc, VERSION_STR)) return error.InvalidVersion;
        },
    }
}

pub fn validateMethodName(method: []const u8) ParseError!void {
    if (method.len == 0) return error.InvalidRequest;
    if (isReservedMethod(method)) return error.InvalidMethod;
}

pub fn isReservedMethod(method: []const u8) bool {
    return std.mem.startsWith(u8, method, "rpc.");
}

fn parseErrorObject(value: std.json.Value) ParseError!types.ErrorObject {
    if (value != .object) return error.InvalidError;

    const code_value = value.object.get("code") orelse return error.InvalidError;
    const message_value = value.object.get("message") orelse return error.InvalidError;

    const code = switch (code_value) {
        .integer => |actual| actual,
        else => return error.InvalidError,
    };

    const message = switch (message_value) {
        .string => |actual| actual,
        else => return error.InvalidError,
    };

    return .{
        .code = code,
        .message = message,
        .data = value.object.get("data"),
    };
}

fn expectVersion(object: std.json.ObjectMap) ParseError!void {
    const version_value = object.get("jsonrpc") orelse return error.InvalidVersion;
    const version = switch (version_value) {
        .string => |actual| actual,
        else => return error.InvalidVersion,
    };

    if (!std.mem.eql(u8, version, VERSION_STR)) return error.InvalidVersion;
}

fn writeError(writer: anytype, err: types.ErrorObject) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"code\":");
    try writer.print("{d}", .{err.code});
    try writer.writeAll(",\"message\":");
    try writeString(writer, err.message);

    if (err.data) |data| {
        try writer.writeAll(",\"data\":");
        try writeValue(writer, data);
    }

    try writer.writeByte('}');
}

fn writeId(writer: anytype, id: types.Id) !void {
    switch (id) {
        .string => |actual| try writeString(writer, actual),
        .number => |actual| try writer.print("{d}", .{actual}),
        .float => |actual| try writer.print("{d}", .{actual}),
        .null => try writer.writeAll("null"),
    }
}

fn writeValue(writer: anytype, value: std.json.Value) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

fn writeString(writer: anytype, value: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

const VERSION_STR = types.VERSION;
