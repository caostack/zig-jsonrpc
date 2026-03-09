const std = @import("std");
const jsonrpc = @import("jsonrpc");
const testing = std.testing;

test "spec example request parses" {
    var parsed = try jsonrpc.parseRequest(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"subtract\",\"params\":[42,23],\"id\":1}",
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("subtract", parsed.request.method);
    try testing.expect(parsed.request.id.?.eql(.{ .number = 1 }));
}

test "spec example notification parses" {
    var parsed = try jsonrpc.parseRequest(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"update\",\"params\":[1,2,3,4,5]}",
    );
    defer parsed.deinit();

    try testing.expect(parsed.request.isNotification());
}

test "spec example error response parses" {
    var parsed = try jsonrpc.parseResponse(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"},\"id\":\"1\"}",
    );
    defer parsed.deinit();

    try testing.expect(parsed.response == .err);
    try testing.expectEqual(@as(i64, -32601), parsed.response.err.err.code);
}
