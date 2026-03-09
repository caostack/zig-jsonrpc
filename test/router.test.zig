const std = @import("std");
const jsonrpc = @import("jsonrpc");
const testing = std.testing;

test "dispatch decodes params and encodes result through typed request handler" {
    const Params = struct {
        a: i32,
        b: i32,
    };
    const Result = struct {
        sum: i32,
    };

    const Handlers = struct {
        fn add(_: std.mem.Allocator, params: Params) !Result {
            return .{ .sum = params.a + params.b };
        }
    };

    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();
    try router.registerRequest(Params, Result, "math/add", Handlers.add);

    var object = std.json.ObjectMap.init(testing.allocator);
    defer object.deinit();
    try object.put("a", .{ .integer = 2 });
    try object.put("b", .{ .integer = 5 });

    var response = router.dispatch(testing.allocator, .{
        .method = "math/add",
        .params = .{ .object = object },
        .id = .{ .number = 7 },
    }).?;
    defer switch (response) {
        .success => |*success| jsonrpc.deinitValue(testing.allocator, &success.result),
        .err => |*failure| if (failure.err.data) |*data| jsonrpc.deinitValue(testing.allocator, data),
    };

    try testing.expect(response == .success);
    try testing.expect(response.success.id.eql(.{ .number = 7 }));
    try testing.expectEqual(@as(i64, 7), response.success.result.object.get("sum").?.integer);
}

test "dispatch returns method not found for unknown request" {
    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();

    const response = router.dispatch(testing.allocator, .{
        .method = "missing",
        .id = .{ .number = 1 },
    }).?;

    try testing.expect(response == .err);
    try testing.expectEqual(@as(i64, @intFromEnum(jsonrpc.ErrorCode.method_not_found)), response.err.err.code);
}

test "dispatch translates params decode errors to invalid params" {
    const Params = struct {
        count: u32,
    };

    const Handlers = struct {
        fn echo(_: std.mem.Allocator, params: Params) !u32 {
            return params.count;
        }
    };

    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();
    try router.registerRequest(Params, u32, "echo/count", Handlers.echo);

    var object = std.json.ObjectMap.init(testing.allocator);
    defer object.deinit();
    try object.put("count", .{ .string = "bad" });

    const response = router.dispatch(testing.allocator, .{
        .method = "echo/count",
        .params = .{ .object = object },
        .id = .{ .number = 3 },
    }).?;

    try testing.expect(response == .err);
    try testing.expectEqual(@as(i64, @intFromEnum(jsonrpc.ErrorCode.invalid_params)), response.err.err.code);
}

test "dispatch translates handler errors" {
    const Params = struct {
        count: i32,
    };

    const Handlers = struct {
        fn fail(_: std.mem.Allocator, _: Params) error{Boom}!i32 {
            return error.Boom;
        }
    };

    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();
    try router.registerRequest(Params, i32, "explode", Handlers.fail);

    var object = std.json.ObjectMap.init(testing.allocator);
    defer object.deinit();
    try object.put("count", .{ .integer = 1 });

    const response = router.dispatch(testing.allocator, .{
        .method = "explode",
        .params = .{ .object = object },
        .id = .{ .number = 4 },
    }).?;

    try testing.expect(response == .err);
    try testing.expectEqual(@as(i64, @intFromEnum(jsonrpc.ErrorCode.internal_error)), response.err.err.code);
    try testing.expectEqualStrings("Boom", response.err.err.message);
}

test "dispatch runs notification handler and returns null" {
    const Params = struct {
        name: []const u8,
    };

    const State = struct {
        var called = false;
        var last_name: []const u8 = "";
    };

    const Handlers = struct {
        fn notify(_: std.mem.Allocator, params: Params) !void {
            State.called = true;
            State.last_name = params.name;
        }
    };

    State.called = false;
    State.last_name = "";

    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();
    try router.registerNotification(Params, "notify/name", Handlers.notify);

    var object = std.json.ObjectMap.init(testing.allocator);
    defer object.deinit();
    try object.put("name", .{ .string = "alex" });

    const response = router.dispatch(testing.allocator, .{
        .method = "notify/name",
        .params = .{ .object = object },
    });

    try testing.expect(response == null);
    try testing.expect(State.called);
    try testing.expectEqualStrings("alex", State.last_name);
}
