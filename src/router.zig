//! JSON-RPC 2.0 method dispatch and handler registry.

const std = @import("std");
const codec = @import("codec.zig");
const serde = @import("serde.zig");
const types = @import("types.zig");

pub const RequestHandler = *const fn (std.mem.Allocator, types.Request) types.Response;
pub const NotificationHandler = *const fn (std.mem.Allocator, types.Request) void;

pub const Router = struct {
    request_handlers: std.StringHashMap(RequestHandler),
    notification_handlers: std.StringHashMap(NotificationHandler),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .request_handlers = std.StringHashMap(RequestHandler).init(allocator),
            .notification_handlers = std.StringHashMap(NotificationHandler).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.request_handlers.deinit();
        self.notification_handlers.deinit();
    }

    pub fn registerRequest(
        self: *Self,
        comptime Params: type,
        comptime Result: type,
        method: []const u8,
        comptime handler: fn (std.mem.Allocator, Params) anyerror!Result,
    ) !void {
        try serde.validateMethodName(method);

        self.mutex.lock();
        defer self.mutex.unlock();

        const Wrapped = struct {
            fn call(allocator: std.mem.Allocator, request: types.Request) types.Response {
                const request_id = request.id.?;

                const params = codec.decodeParams(Params, request.params) catch |err| {
                    return types.Response.errorResponse(
                        request_id,
                        .invalid_params,
                        invalidParamsMessage(err),
                        null,
                    );
                };

                const result = handler(allocator, params) catch |err| {
                    const translated = translateError(err);
                    return types.Response.errorResponseCode(request_id, translated.code, translated.message, null);
                };

                const encoded = codec.encodeResult(allocator, result) catch |err| {
                    const translated = translateError(err);
                    return types.Response.errorResponseCode(request_id, translated.code, translated.message, null);
                };

                return types.Response.successResponse(request_id, encoded);
            }
        };

        try self.request_handlers.put(method, Wrapped.call);
    }

    pub fn registerNotification(
        self: *Self,
        comptime Params: type,
        method: []const u8,
        comptime handler: fn (std.mem.Allocator, Params) anyerror!void,
    ) !void {
        try serde.validateMethodName(method);

        self.mutex.lock();
        defer self.mutex.unlock();

        const Wrapped = struct {
            fn call(allocator: std.mem.Allocator, request: types.Request) void {
                const params = codec.decodeParams(Params, request.params) catch {
                    return;
                };

                handler(allocator, params) catch {};
            }
        };

        try self.notification_handlers.put(method, Wrapped.call);
    }

    pub fn dispatch(self: *Self, allocator: std.mem.Allocator, request: types.Request) ?types.Response {
        serde.validateMethodName(request.method) catch {
            if (request.isNotification()) return null;
            return types.Response.errorResponse(
                request.id.?,
                .invalid_request,
                types.ErrorCode.invalid_request.message(),
                null,
            );
        };

        if (request.isNotification()) {
            self.mutex.lock();
            const handler = self.notification_handlers.get(request.method);
            self.mutex.unlock();
            const resolved = handler orelse return null;
            resolved(allocator, request);
            return null;
        }

        self.mutex.lock();
        const handler = self.request_handlers.get(request.method) orelse {
            self.mutex.unlock();
            return types.Response.errorResponse(
                request.id.?,
                .method_not_found,
                types.ErrorCode.method_not_found.message(),
                null,
            );
        };
        self.mutex.unlock();

        return handler(allocator, request);
    }

    pub fn hasRequestHandler(self: *Self, method: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.request_handlers.contains(method);
    }

    pub fn hasNotificationHandler(self: *Self, method: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.notification_handlers.contains(method);
    }
};

/// Translate Zig errors into JSON-RPC errors.
pub fn translateError(err: anyerror) types.ErrorObject {
    return switch (err) {
        error.InvalidParams, error.TypeMismatch => .{
            .code = @intFromEnum(types.ErrorCode.invalid_params),
            .message = types.ErrorCode.invalid_params.message(),
        },
        error.MethodNotFound => .{
            .code = @intFromEnum(types.ErrorCode.method_not_found),
            .message = types.ErrorCode.method_not_found.message(),
        },
        error.OutOfMemory => .{
            .code = @intFromEnum(types.ErrorCode.internal_error),
            .message = "Out of memory",
        },
        else => .{
            .code = @intFromEnum(types.ErrorCode.internal_error),
            .message = @errorName(err),
        },
    };
}

fn invalidParamsMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidParams, error.TypeMismatch => types.ErrorCode.invalid_params.message(),
        else => @errorName(err),
    };
}
