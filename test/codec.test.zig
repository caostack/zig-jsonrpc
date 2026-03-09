const std = @import("std");
const jsonrpc = @import("jsonrpc");
const testing = std.testing;

test "decodeParams decodes struct fields" {
    const Params = struct {
        count: i32,
        label: []const u8,
    };

    var object = std.json.ObjectMap.init(testing.allocator);
    defer object.deinit();
    try object.put("count", .{ .integer = 42 });
    try object.put("label", .{ .string = "jobs" });

    const params = try jsonrpc.decodeParams(Params, .{ .object = object });
    try testing.expectEqual(@as(i32, 42), params.count);
    try testing.expectEqualStrings("jobs", params.label);
}

test "decodeParams supports optional and enum fields" {
    const Mode = enum { fast, safe };
    const Params = struct {
        mode: Mode,
        limit: ?u32,
    };

    var object = std.json.ObjectMap.init(testing.allocator);
    defer object.deinit();
    try object.put("mode", .{ .string = "safe" });

    const params = try jsonrpc.decodeParams(Params, .{ .object = object });
    try testing.expectEqual(Mode.safe, params.mode);
    try testing.expectEqual(@as(?u32, null), params.limit);
}

test "decodeParams rejects missing required field" {
    const Params = struct {
        name: []const u8,
    };

    var object = std.json.ObjectMap.init(testing.allocator);
    defer object.deinit();

    try testing.expectError(error.InvalidParams, jsonrpc.decodeParams(Params, .{ .object = object }));
}

test "decodeParams supports void for paramless methods" {
    try jsonrpc.decodeParams(void, null);
    try jsonrpc.decodeParams(void, .{ .null = {} });
    try testing.expectError(error.InvalidParams, jsonrpc.decodeParams(void, .{ .bool = true }));
}

test "encodeResult encodes struct and nested array without leaks" {
    const Payload = struct {
        ok: bool,
        tags: []const []const u8,
    };

    var result = try jsonrpc.encodeResult(testing.allocator, Payload{
        .ok = true,
        .tags = &.{ "alpha", "beta" },
    });
    defer jsonrpc.deinitValue(testing.allocator, &result);

    try testing.expect(result == .object);
    try testing.expectEqual(true, result.object.get("ok").?.bool);
    try testing.expectEqual(@as(usize, 2), result.object.get("tags").?.array.items.len);
    try testing.expectEqualStrings("alpha", result.object.get("tags").?.array.items[0].string);
}

test "encodeResult encodes enums as strings" {
    const Mode = enum { fast, safe };

    var result = try jsonrpc.encodeResult(testing.allocator, Mode.fast);
    defer jsonrpc.deinitValue(testing.allocator, &result);

    try testing.expect(result == .string);
    try testing.expectEqualStrings("fast", result.string);
}
