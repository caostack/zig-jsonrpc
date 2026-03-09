const std = @import("std");
const jsonrpc = @import("jsonrpc");
const testing = std.testing;

test "encodeRequestAlloc serializes request with params and id" {
    var params = try jsonrpc.encodeResult(testing.allocator, .{ .limit = @as(u32, 10) });
    defer jsonrpc.deinitValue(testing.allocator, &params);

    const encoded = try jsonrpc.encodeRequestAlloc(testing.allocator, .{
        .method = "items/list",
        .params = params,
        .id = .{ .number = 9 },
    });
    defer testing.allocator.free(encoded);

    try testing.expect(std.mem.indexOf(u8, encoded, "\"method\":\"items/list\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"id\":9") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"limit\":10") != null);
}

test "encodeRequestAlloc rejects invalid request params shape" {
    try testing.expectError(
        error.InvalidRequest,
        jsonrpc.encodeRequestAlloc(testing.allocator, .{
            .method = "items/list",
            .params = .{ .null = {} },
            .id = .{ .number = 1 },
        }),
    );
}

test "encodeRequestAlloc rejects reserved rpc method prefix" {
    try testing.expectError(
        error.InvalidMethod,
        jsonrpc.encodeRequestAlloc(testing.allocator, .{
            .method = "rpc.internal",
            .id = .{ .number = 1 },
        }),
    );
}

test "encodeRequestBatchAlloc serializes batch" {
    const encoded = try jsonrpc.encodeRequestBatchAlloc(testing.allocator, &.{
        .{ .method = "ping", .id = .{ .number = 1 } },
        .{ .method = "notify" },
    });
    defer testing.allocator.free(encoded);

    try testing.expect(std.mem.startsWith(u8, encoded, "["));
    try testing.expect(std.mem.indexOf(u8, encoded, "\"method\":\"ping\"") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"method\":\"notify\"") != null);
}

test "parseRequest parses notification and keeps params accessible" {
    var parsed = try jsonrpc.parseRequest(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"name\":\"alex\"}}",
    );
    defer parsed.deinit();

    try testing.expect(parsed.request.isNotification());
    try testing.expectEqualStrings("session/update", parsed.request.method);
    try testing.expectEqualStrings("alex", parsed.request.params.?.object.get("name").?.string);
}

test "parseRequest rejects reserved rpc method prefix" {
    try testing.expectError(
        error.InvalidMethod,
        jsonrpc.parseRequest(
            testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"rpc.internal\",\"id\":1}",
        ),
    );
}

test "parseRequest accepts float id values" {
    var parsed = try jsonrpc.parseRequest(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"method\":\"jobs/get\",\"id\":1.5}",
    );
    defer parsed.deinit();

    try testing.expect(parsed.request.id != null);
    try testing.expect(parsed.request.id.?.eql(.{ .float = 1.5 }));
}

test "parseResponse parses success response" {
    var parsed = try jsonrpc.parseResponse(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"result\":{\"sum\":7},\"id\":1}",
    );
    defer parsed.deinit();

    try testing.expect(parsed.response == .success);
    try testing.expect(parsed.response.success.id.eql(.{ .number = 1 }));
    try testing.expectEqual(@as(i64, 7), parsed.response.success.result.object.get("sum").?.integer);
}

test "parseResponse parses custom error codes" {
    var parsed = try jsonrpc.parseResponse(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32042,\"message\":\"Rate limited\"},\"id\":null}",
    );
    defer parsed.deinit();

    try testing.expect(parsed.response == .err);
    try testing.expectEqual(@as(i64, -32042), parsed.response.err.err.code);
    try testing.expect(parsed.response.err.id.eql(.null));
}

test "parseResponse accepts float id values" {
    var parsed = try jsonrpc.parseResponse(
        testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":1.5}",
    );
    defer parsed.deinit();

    try testing.expect(parsed.response == .success);
    try testing.expect(parsed.response.success.id.eql(.{ .float = 1.5 }));
}

test "parseRequest rejects invalid params shape" {
    try testing.expectError(
        error.InvalidRequest,
        jsonrpc.parseRequest(
            testing.allocator,
            "{\"jsonrpc\":\"2.0\",\"method\":\"bad\",\"params\":123}",
        ),
    );
}

test "parseResponse rejects batch payloads" {
    try testing.expectError(
        error.UnsupportedBatch,
        jsonrpc.parseResponse(testing.allocator, "[]"),
    );
}

test "parseResponseBatch parses multiple responses" {
    var parsed = try jsonrpc.parseResponseBatch(testing.allocator,
        \\[
        \\  {"jsonrpc":"2.0","result":{"sum":7},"id":1},
        \\  {"jsonrpc":"2.0","error":{"code":-32001,"message":"Busy"},"id":"job-2"}
        \\]
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.responses.len);
    try testing.expect(parsed.responses[0] == .success);
    try testing.expect(parsed.responses[1] == .err);
}

test "parseResponseBatch rejects empty batch" {
    try testing.expectError(error.InvalidResponse, jsonrpc.parseResponseBatch(testing.allocator, "[]"));
}
