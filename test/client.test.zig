const std = @import("std");
const jsonrpc = @import("jsonrpc");
const testing = std.testing;

const MockTransportState = struct {
    allocator: std.mem.Allocator,
    last_call_request: ?[]u8 = null,
    last_notify_request: ?[]u8 = null,
    response_payload: []const u8 = "",

    fn deinit(self: *MockTransportState) void {
        if (self.last_call_request) |bytes| self.allocator.free(bytes);
        if (self.last_notify_request) |bytes| self.allocator.free(bytes);
    }
};

fn mockCall(context: ?*anyopaque, allocator: std.mem.Allocator, request_bytes: []const u8) ![]u8 {
    const state: *MockTransportState = @ptrCast(@alignCast(context.?));
    if (state.last_call_request) |bytes| allocator.free(bytes);
    state.last_call_request = try allocator.dupe(u8, request_bytes);
    return allocator.dupe(u8, state.response_payload);
}

fn mockNotify(context: ?*anyopaque, request_bytes: []const u8) !void {
    const state: *MockTransportState = @ptrCast(@alignCast(context.?));
    if (state.last_notify_request) |bytes| state.allocator.free(bytes);
    state.last_notify_request = try state.allocator.dupe(u8, request_bytes);
}

test "client call sends request and decodes typed success" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "{\"jsonrpc\":\"2.0\",\"result\":{\"sum\":9},\"id\":1}",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const Params = struct { a: i32, b: i32 };
    const Result = struct { sum: i32 };

    var outcome = try client.call(testing.allocator, Params, Result, "math/add", .{ .a = 4, .b = 5 });
    defer outcome.deinit(testing.allocator);

    try testing.expect(outcome == .success);
    try testing.expectEqual(@as(i32, 9), outcome.success.sum);
    try testing.expect(state.last_call_request != null);
    try testing.expect(std.mem.indexOf(u8, state.last_call_request.?, "\"method\":\"math/add\"") != null);
}

test "client call returns remote rpc error" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32001,\"message\":\"Busy\",\"data\":{\"retry\":true}},\"id\":1}",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    var outcome = try client.call(testing.allocator, void, void, "server/ping", {});
    defer outcome.deinit(testing.allocator);

    try testing.expect(outcome == .rpc_error);
    try testing.expectEqual(@as(i64, -32001), outcome.rpc_error.code);
    try testing.expectEqualStrings("Busy", outcome.rpc_error.message);
    try testing.expectEqual(true, outcome.rpc_error.data.?.object.get("retry").?.bool);
}

test "client call decodes null result into void" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":1}",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    var outcome = try client.call(testing.allocator, void, void, "server/ping", {});
    defer outcome.deinit(testing.allocator);

    try testing.expect(outcome == .success);
}

test "client call rejects mismatched response id" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":2}",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    try testing.expectError(
        error.InvalidResponseId,
        client.call(testing.allocator, void, void, "server/ping", {}),
    );
}

test "client call accepts numerically equivalent response id" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "{\"jsonrpc\":\"2.0\",\"result\":true,\"id\":1.0}",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    var outcome = try client.call(testing.allocator, void, bool, "server/ping", {});
    defer outcome.deinit(testing.allocator);

    try testing.expect(outcome == .success);
    try testing.expect(outcome.success);
}

test "client notify sends notification without id" {
    var state = MockTransportState{
        .allocator = testing.allocator,
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    try client.notify(testing.allocator, struct { name: []const u8 }, "events/publish", .{ .name = "alex" });

    try testing.expect(state.last_notify_request != null);
    try testing.expect(std.mem.indexOf(u8, state.last_notify_request.?, "\"method\":\"events/publish\"") != null);
    try testing.expect(std.mem.indexOf(u8, state.last_notify_request.?, "\"id\"") == null);
}

test "client callBatch sends batch and clones responses" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload =
        \\[
        \\  {"jsonrpc":"2.0","result":{"sum":9},"id":1},
        \\  {"jsonrpc":"2.0","error":{"code":-32001,"message":"Busy"},"id":"job-2"}
        \\]
        ,
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const requests = [_]jsonrpc.Request{
        .{ .method = "math/add", .params = try jsonrpc.encodeResult(testing.allocator, .{ .a = 4, .b = 5 }), .id = .{ .number = 1 } },
        .{ .method = "jobs/get", .params = try jsonrpc.encodeResult(testing.allocator, .{ .id = "job-2" }), .id = .{ .string = "job-2" } },
    };
    defer {
        var first = requests[0].params.?;
        jsonrpc.deinitValue(testing.allocator, &first);
        var second = requests[1].params.?;
        jsonrpc.deinitValue(testing.allocator, &second);
    }

    const responses = try client.callBatch(testing.allocator, &requests);
    defer jsonrpc.deinitBatchResponses(testing.allocator, responses);

    try testing.expectEqual(@as(usize, 2), responses.len);
    try testing.expect(responses[0].id.eql(.{ .number = 1 }));
    try testing.expect(responses[0].response == .success);
    try testing.expect(responses[1].response == .err);
    try testing.expectEqualStrings("Busy", responses[1].response.err.err.message);
    try testing.expect(state.last_call_request != null);
    try testing.expect(std.mem.startsWith(u8, state.last_call_request.?, "["));
}

test "client callBatch accepts numerically equivalent response ids" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "[{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":1.0}]",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const requests = [_]jsonrpc.Request{
        .{ .method = "ping", .id = .{ .number = 1 } },
    };

    const responses = try client.callBatch(testing.allocator, &requests);
    defer jsonrpc.deinitBatchResponses(testing.allocator, responses);

    try testing.expectEqual(@as(usize, 1), responses.len);
    try testing.expect(responses[0].id.eql(.{ .float = 1.0 }));
}

test "client callBatch rejects unknown response id" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "[{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":99}]",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const requests = [_]jsonrpc.Request{
        .{ .method = "ping", .id = .{ .number = 1 } },
    };

    try testing.expectError(error.InvalidResponseId, client.callBatch(testing.allocator, &requests));
}

test "client notifyBatch sends only notifications" {
    var state = MockTransportState{
        .allocator = testing.allocator,
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const requests = [_]jsonrpc.Request{
        .{ .method = "events/a" },
        .{ .method = "events/b", .params = try jsonrpc.encodeResult(testing.allocator, .{ .name = "alex" }) },
    };
    defer {
        var second = requests[1].params.?;
        jsonrpc.deinitValue(testing.allocator, &second);
    }

    try client.notifyBatch(testing.allocator, &requests);

    try testing.expect(state.last_notify_request != null);
    try testing.expect(std.mem.startsWith(u8, state.last_notify_request.?, "["));
}

test "client callBatch rejects duplicate numeric request ids" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "[]",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const requests = [_]jsonrpc.Request{
        .{ .method = "a", .id = .{ .number = 1 } },
        .{ .method = "b", .id = .{ .number = 1 } },
    };

    try testing.expectError(error.DuplicateRequestId, client.callBatch(testing.allocator, &requests));
}

test "client callBatch accepts a single null id request" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "[{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":null}]",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const requests = [_]jsonrpc.Request{
        .{ .method = "jobs/poll", .id = .null },
    };

    const responses = try client.callBatch(testing.allocator, &requests);
    defer jsonrpc.deinitBatchResponses(testing.allocator, responses);

    try testing.expectEqual(@as(usize, 1), responses.len);
    try testing.expect(responses[0].id.eql(.null));
}

test "client callBatch rejects duplicate null request ids" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload = "[]",
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const requests = [_]jsonrpc.Request{
        .{ .method = "a", .id = .null },
        .{ .method = "b", .id = .null },
    };

    try testing.expectError(error.DuplicateRequestId, client.callBatch(testing.allocator, &requests));
}

test "client callBatch rejects duplicate response ids" {
    var state = MockTransportState{
        .allocator = testing.allocator,
        .response_payload =
        \\[
        \\  {"jsonrpc":"2.0","result":null,"id":1},
        \\  {"jsonrpc":"2.0","error":{"code":-32000,"message":"dup"},"id":1}
        \\]
        ,
    };
    defer state.deinit();

    var client = jsonrpc.Client.init(.{
        .context = &state,
        .callFn = mockCall,
        .notifyFn = mockNotify,
    });

    const requests = [_]jsonrpc.Request{
        .{ .method = "a", .id = .{ .number = 1 } },
    };

    try testing.expectError(error.DuplicateResponseId, client.callBatch(testing.allocator, &requests));
}

test "async client tracks pending completion timeout and cancel" {
    var client = jsonrpc.AsyncClient.init(testing.allocator);
    defer client.deinit();

    const started = try client.startCall(
        testing.allocator,
        struct { value: i32 },
        "jobs/run",
        .{ .value = 1 },
        .{ .now_ms = 100, .timeout_ms = 50 },
    );
    defer testing.allocator.free(started.request_bytes);

    try testing.expect(client.hasPending(started.id));
    try testing.expectEqual(@as(usize, 1), try client.expireTimeouts(151));

    var completion = client.takeCompletion(started.id).?;
    defer completion.deinit(testing.allocator);
    try testing.expect(completion == .timed_out);

    const started_cancel = try client.startCall(
        testing.allocator,
        void,
        "jobs/cancel",
        {},
        .{},
    );
    defer testing.allocator.free(started_cancel.request_bytes);

    try testing.expect(try client.cancel(started_cancel.id));
    var cancelled = client.takeCompletion(started_cancel.id).?;
    defer cancelled.deinit(testing.allocator);
    try testing.expect(cancelled == .cancelled);
}

test "async client accepts batch responses and rejects duplicate ids" {
    var client = jsonrpc.AsyncClient.init(testing.allocator);
    defer client.deinit();

    const started_a = try client.startCall(testing.allocator, void, "a", {}, .{});
    defer testing.allocator.free(started_a.request_bytes);
    const started_b = try client.startCall(testing.allocator, void, "b", {}, .{});
    defer testing.allocator.free(started_b.request_bytes);

    const payload = try std.fmt.allocPrint(
        testing.allocator,
        "[{{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":{d}}},{{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":{d}}}]",
        .{ started_a.id, started_b.id },
    );
    defer testing.allocator.free(payload);

    try client.acceptResponseBytes(testing.allocator, payload);

    var first = client.takeCompletion(started_a.id).?;
    defer first.deinit(testing.allocator);
    try testing.expect(first == .response);

    const dup_started = try client.startCall(testing.allocator, void, "c", {}, .{});
    defer testing.allocator.free(dup_started.request_bytes);
    const dup_payload = try std.fmt.allocPrint(
        testing.allocator,
        "[{{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":{d}}},{{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":{d}}}]",
        .{ dup_started.id, dup_started.id },
    );
    defer testing.allocator.free(dup_payload);

    try testing.expectError(error.DuplicateResponseId, client.acceptResponseBytes(testing.allocator, dup_payload));
}

test "async client accepts numerically equivalent integer response ids" {
    var client = jsonrpc.AsyncClient.init(testing.allocator);
    defer client.deinit();

    const started = try client.startCall(testing.allocator, void, "a", {}, .{});
    defer testing.allocator.free(started.request_bytes);

    const payload = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"result\":null,\"id\":{d}.0}}",
        .{started.id},
    );
    defer testing.allocator.free(payload);

    try client.acceptResponseBytes(testing.allocator, payload);

    var completion = client.takeCompletion(started.id).?;
    defer completion.deinit(testing.allocator);
    try testing.expect(completion == .response);
}
