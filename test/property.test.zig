const std = @import("std");
const jsonrpc = @import("jsonrpc");
const testing = std.testing;

test "request encode parse roundtrip property" {
    var prng = std.Random.DefaultPrng.init(0xC0DEC0DE);
    const random = prng.random();

    for (0..64) |i| {
        const method = try std.fmt.allocPrint(testing.allocator, "m/{d}", .{i});
        defer testing.allocator.free(method);

        var params = try jsonrpc.encodeResult(testing.allocator, .{
            .value = random.intRangeAtMost(i32, -1000, 1000),
        });
        defer jsonrpc.deinitValue(testing.allocator, &params);

        const encoded = try jsonrpc.encodeRequestAlloc(testing.allocator, .{
            .method = method,
            .params = params,
            .id = .{ .number = @intCast(i + 1) },
        });
        defer testing.allocator.free(encoded);

        var parsed = try jsonrpc.parseRequest(testing.allocator, encoded);
        defer parsed.deinit();

        try testing.expectEqualStrings(method, parsed.request.method);
        try testing.expect(parsed.request.id.?.eql(.{ .number = @intCast(i + 1) }));
    }
}

test "server raw handler survives random invalid input" {
    var prng = std.Random.DefaultPrng.init(0xBAD5EED);
    const random = prng.random();

    var router = jsonrpc.Router.init(testing.allocator);
    defer router.deinit();

    var buffer: [64]u8 = undefined;
    for (0..64) |_| {
        const len = random.intRangeAtMost(usize, 1, buffer.len);
        random.bytes(buffer[0..len]);
        const maybe_response = jsonrpc.handleBytesAlloc(testing.allocator, &router, buffer[0..len]) catch continue;
        if (maybe_response) |response| testing.allocator.free(response);
    }
}
