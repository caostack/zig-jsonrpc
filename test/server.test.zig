const std = @import("std");
const jsonrpc = @import("jsonrpc");
const testing = std.testing;

test "handleBytesAlloc returns parse error response for invalid json" {
    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();

    const encoded = (try jsonrpc.handleBytesAlloc(testing.allocator, &router, "{")).?;
    defer testing.allocator.free(encoded);

    var parsed = try jsonrpc.parseResponse(testing.allocator, encoded);
    defer parsed.deinit();

    try testing.expect(parsed.response == .err);
    try testing.expectEqual(@as(i64, @intFromEnum(jsonrpc.ErrorCode.parse_error)), parsed.response.err.err.code);
    try testing.expect(parsed.response.err.id.eql(.null));
}

test "handleBytesAlloc returns invalid request for empty batch" {
    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();

    const encoded = (try jsonrpc.handleBytesAlloc(testing.allocator, &router, "[]")).?;
    defer testing.allocator.free(encoded);

    var parsed = try jsonrpc.parseResponse(testing.allocator, encoded);
    defer parsed.deinit();

    try testing.expect(parsed.response == .err);
    try testing.expectEqual(@as(i64, @intFromEnum(jsonrpc.ErrorCode.invalid_request)), parsed.response.err.err.code);
    try testing.expect(parsed.response.err.id.eql(.null));
}

test "handleBytesAlloc processes mixed batch and omits notifications" {
    const Params = struct {
        value: i32,
    };
    const Result = struct {
        doubled: i32,
    };

    const State = struct {
        var notified = false;
    };

    const Handlers = struct {
        fn double(_: std.mem.Allocator, params: Params) !Result {
            return .{ .doubled = params.value * 2 };
        }

        fn notify(_: std.mem.Allocator, _: Params) !void {
            State.notified = true;
        }
    };

    State.notified = false;

    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();
    try router.registerRequest(Params, Result, "math/double", Handlers.double);
    try router.registerNotification(Params, "math/notify", Handlers.notify);

    const batch =
        \\[
        \\  {"jsonrpc":"2.0","method":"math/double","params":{"value":3},"id":1},
        \\  {"jsonrpc":"2.0","method":"math/notify","params":{"value":1}},
        \\  {"foo":"bar"},
        \\  {"jsonrpc":"2.0","method":"missing","id":2}
        \\]
    ;

    const encoded = (try jsonrpc.handleBytesAlloc(testing.allocator, &router, batch)).?;
    defer testing.allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, encoded, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value == .array);
    try testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
    try testing.expect(State.notified);
}

test "handleBytesAlloc invalid request uses parsed id when available" {
    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();

    const encoded = (try jsonrpc.handleBytesAlloc(
        testing.allocator,
        &router,
        "{\"jsonrpc\":\"2.0\",\"method\":\"ok\",\"params\":1,\"id\":7}",
    )).?;
    defer testing.allocator.free(encoded);

    var parsed = try jsonrpc.parseResponse(testing.allocator, encoded);
    defer parsed.deinit();

    try testing.expect(parsed.response.err.id.eql(.{ .number = 7 }));
}
