//! JSON-RPC 2.0 Types Tests

const std = @import("std");
const jsonrpc = @import("jsonrpc");
const testing = std.testing;

test "VERSION is 2.0" {
    try testing.expectEqualStrings("2.0", jsonrpc.VERSION);
}

test "Id.eql compares identifiers" {
    // Same number
    try testing.expect(jsonrpc.Id.eql(.{ .number = 1 }, .{ .number = 1 }));
    // Different numbers
    try testing.expect(!jsonrpc.Id.eql(.{ .number = 1 }, .{ .number = 2 }));
    // Same string
    try testing.expect(jsonrpc.Id.eql(.{ .string = "abc" }, .{ .string = "abc" }));
    // Different strings
    try testing.expect(!jsonrpc.Id.eql(.{ .string = "abc" }, .{ .string = "xyz" }));
    // Both null
    try testing.expect(jsonrpc.Id.eql(.null, .null));
    // Mixed types
    try testing.expect(!jsonrpc.Id.eql(.{ .number = 1 }, .{ .string = "1" }));
    // Equivalent JSON numbers
    try testing.expect(jsonrpc.Id.eql(.{ .number = 1 }, .{ .float = 1.0 }));
    // Non-equivalent JSON numbers
    try testing.expect(!jsonrpc.Id.eql(.{ .number = 1 }, .{ .float = 1.5 }));
}

test "Request.isNotification detects notification" {
    // No id = notification
    const req = jsonrpc.Request{ .method = "notify" };
    try testing.expect(req.isNotification());

    // Has id = not notification
    const req_with_id = jsonrpc.Request{ .method = "call", .id = .{ .number = 1 } };
    try testing.expect(!req_with_id.isNotification());
}

test "ErrorCode has standard values" {
    try testing.expectEqual(@as(i64, -32700), @intFromEnum(jsonrpc.ErrorCode.parse_error));
    try testing.expectEqual(@as(i64, -32600), @intFromEnum(jsonrpc.ErrorCode.invalid_request));
    try testing.expectEqual(@as(i64, -32601), @intFromEnum(jsonrpc.ErrorCode.method_not_found));
    try testing.expectEqual(@as(i64, -32602), @intFromEnum(jsonrpc.ErrorCode.invalid_params));
    try testing.expectEqual(@as(i64, -32603), @intFromEnum(jsonrpc.ErrorCode.internal_error));
}

test "ErrorCode.message returns description" {
    try testing.expectEqualStrings("Parse error", jsonrpc.ErrorCode.parse_error.message());
    try testing.expectEqualStrings("Method not found", jsonrpc.ErrorCode.method_not_found.message());
}

test "ErrorCode.fromInt resolves known values" {
    try testing.expectEqual(jsonrpc.ErrorCode.invalid_params, jsonrpc.ErrorCode.fromInt(-32602).?);
    try testing.expect(jsonrpc.ErrorCode.fromInt(-32099) == null);
}
