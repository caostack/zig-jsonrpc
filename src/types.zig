//! JSON-RPC 2.0 core types.

const std = @import("std");

/// JSON-RPC protocol version.
pub const VERSION = "2.0";

/// JSON-RPC request identifier.
pub const Id = union(enum) {
    string: []const u8,
    number: i64,
    null,

    pub fn eql(a: Id, b: Id) bool {
        const a_tag = std.meta.activeTag(a);
        const b_tag = std.meta.activeTag(b);
        if (a_tag != b_tag) return false;

        return switch (a) {
            .string => |value| std.mem.eql(u8, value, b.string),
            .number => |value| value == b.number,
            .null => true,
        };
    }
};

/// Standard JSON-RPC error codes.
pub const ErrorCode = enum(i64) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    pub fn message(code: ErrorCode) []const u8 {
        return switch (code) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
        };
    }

    pub fn fromInt(value: i64) ?ErrorCode {
        return std.meta.intToEnum(ErrorCode, value) catch null;
    }
};

/// JSON-RPC error payload.
pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,

    pub fn knownCode(self: ErrorObject) ?ErrorCode {
        return ErrorCode.fromInt(self.code);
    }
};

/// JSON-RPC request.
pub const Request = struct {
    jsonrpc: []const u8 = VERSION,
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?Id = null,

    pub fn isNotification(self: Request) bool {
        return self.id == null;
    }
};

/// JSON-RPC success response.
pub const SuccessResponse = struct {
    jsonrpc: []const u8 = VERSION,
    result: std.json.Value,
    id: Id,
};

/// JSON-RPC error response.
pub const ErrorResponse = struct {
    jsonrpc: []const u8 = VERSION,
    err: ErrorObject,
    id: Id,
};

/// JSON-RPC response.
pub const Response = union(enum) {
    success: SuccessResponse,
    err: ErrorResponse,

    pub fn successResponse(id: Id, result: std.json.Value) Response {
        return .{
            .success = .{
                .result = result,
                .id = id,
            },
        };
    }

    pub fn errorResponse(id: Id, code: ErrorCode, message: []const u8, data: ?std.json.Value) Response {
        return errorResponseCode(id, @intFromEnum(code), message, data);
    }

    pub fn errorResponseCode(id: Id, code: i64, message: []const u8, data: ?std.json.Value) Response {
        return .{
            .err = .{
                .err = .{
                    .code = code,
                    .message = message,
                    .data = data,
                },
                .id = id,
            },
        };
    }
};
