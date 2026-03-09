//! JSON-RPC 2.0 server-side raw request handling.

const std = @import("std");
const codec = @import("codec.zig");
const router_mod = @import("router.zig");
const serde = @import("serde.zig");
const types = @import("types.zig");

pub fn handleBytesAlloc(
    allocator: std.mem.Allocator,
    router: *router_mod.Router,
    bytes: []const u8,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        const response = errorResponseForRequestFailure(error.InvalidJson, null);
        return try serde.encodeResponseAlloc(allocator, response);
    };
    defer parsed.deinit();

    return handleValueAlloc(allocator, router, parsed.value);
}

pub fn errorResponseForRequestFailure(err: serde.ParseError, id: ?types.Id) types.Response {
    return switch (err) {
        error.InvalidJson => types.Response.errorResponse(.null, .parse_error, types.ErrorCode.parse_error.message(), null),
        else => types.Response.errorResponse(
            id orelse .null,
            .invalid_request,
            types.ErrorCode.invalid_request.message(),
            null,
        ),
    };
}

fn handleValueAlloc(
    allocator: std.mem.Allocator,
    router: *router_mod.Router,
    value: std.json.Value,
) !?[]u8 {
    return switch (value) {
        .array => |array| try handleBatchAlloc(allocator, router, array.items),
        else => if (try handleItem(allocator, router, value)) |response| blk: {
            var owned = response;
            defer deinitResponse(allocator, &owned);
            break :blk try serde.encodeResponseAlloc(allocator, owned);
        } else null,
    };
}

fn handleBatchAlloc(
    allocator: std.mem.Allocator,
    router: *router_mod.Router,
    items: []const std.json.Value,
) !?[]u8 {
    if (items.len == 0) {
        const response = errorResponseForRequestFailure(error.InvalidRequest, null);
        return try serde.encodeResponseAlloc(allocator, response);
    }

    var responses = std.ArrayList(types.Response){};
    defer responses.deinit(allocator);

    for (items) |item| {
        if (try handleItem(allocator, router, item)) |response| {
            try responses.append(allocator, response);
        }
    }
    defer {
        for (responses.items) |*response| {
            deinitResponse(allocator, response);
        }
    }

    if (responses.items.len == 0) return null;
    return try serde.encodeResponseBatchAlloc(allocator, responses.items);
}

fn handleItem(
    allocator: std.mem.Allocator,
    router: *router_mod.Router,
    value: std.json.Value,
) !?types.Response {
    const request = serde.parseRequestValue(value) catch |err| {
        return errorResponseForRequestFailure(err, extractId(value));
    };

    return router.dispatch(allocator, request);
}

fn extractId(value: std.json.Value) ?types.Id {
    if (value != .object) return null;
    const id_value = value.object.get("id") orelse return null;
    return serde.parseIdValue(id_value) catch null;
}

fn deinitResponse(allocator: std.mem.Allocator, response: *types.Response) void {
    switch (response.*) {
        .success => |*success| codec.deinitValue(allocator, &success.result),
        .err => |*failure| if (failure.err.data) |*data| codec.deinitValue(allocator, data),
    }
}
