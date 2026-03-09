//! JSON-RPC params decoding and result encoding.

const std = @import("std");

pub const DecodeError = error{
    InvalidParams,
    TypeMismatch,
    OutOfMemory,
};

/// Decode request params into a strongly typed Zig value.
pub fn decodeParams(comptime T: type, value: ?std.json.Value) DecodeError!T {
    return decodeMaybeValue(T, value);
}

/// Decode a JSON result value into a strongly typed Zig value.
pub fn decodeResult(comptime T: type, value: std.json.Value) DecodeError!T {
    return decodeValue(T, value);
}

/// Deep-clone a JSON value into memory owned by `allocator`.
pub fn cloneValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .{ .null = {} },
        .bool => |actual| .{ .bool = actual },
        .integer => |actual| .{ .integer = actual },
        .float => |actual| .{ .float = actual },
        .number_string => |actual| .{ .number_string = try allocator.dupe(u8, actual) },
        .string => |actual| .{ .string = try allocator.dupe(u8, actual) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            errdefer {
                var cleanup = std.json.Value{ .array = cloned };
                deinitValue(allocator, &cleanup);
            }

            for (array.items) |item| {
                try cloned.append(try cloneValue(allocator, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = std.json.ObjectMap.init(allocator);
            errdefer {
                var cleanup = std.json.Value{ .object = cloned };
                deinitValue(allocator, &cleanup);
            }

            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);

                const cloned_value = try cloneValue(allocator, entry.value_ptr.*);
                errdefer {
                    var cleanup = cloned_value;
                    deinitValue(allocator, &cleanup);
                }

                try cloned.put(key, cloned_value);
            }
            break :blk .{ .object = cloned };
        },
    };
}

fn decodeMaybeValue(comptime T: type, value: ?std.json.Value) DecodeError!T {
    if (T == void) {
        if (value == null) return {};
        if (value.? == .null) return {};
        return error.InvalidParams;
    }

    const actual = value orelse return error.InvalidParams;
    return decodeValue(T, actual);
}

/// Encode a Zig value into a JSON value owned by `allocator`.
pub fn encodeResult(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .void => std.json.Value{ .null = {} },
        .null => std.json.Value{ .null = {} },
        .bool => std.json.Value{ .bool = value },
        .int, .comptime_int => std.json.Value{ .integer = @intCast(value) },
        .float, .comptime_float => std.json.Value{ .float = @floatCast(value) },
        .@"enum" => std.json.Value{ .string = try allocator.dupe(u8, @tagName(value)) },
        .optional => if (value) |unwrapped|
            try encodeResult(allocator, unwrapped)
        else
            std.json.Value{ .null = {} },
        .pointer => |pointer_info| try encodePointer(allocator, pointer_info, value),
        .array => |array_info| if (array_info.child == u8)
            std.json.Value{ .string = try allocator.dupe(u8, value[0..]) }
        else
            try encodeSlice(allocator, value[0..]),
        .@"struct" => try encodeStruct(allocator, value),
        else => error.InvalidParams,
    };
}

/// Release heap memory owned by a JSON value created by `encodeResult`.
pub fn deinitValue(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string => |bytes| allocator.free(bytes),
        .number_string => |bytes| allocator.free(bytes),
        .array => |*array| {
            for (array.items) |*item| {
                deinitValue(allocator, item);
            }
            array.deinit();
        },
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitValue(allocator, entry.value_ptr);
            }
            object.deinit();
        },
        else => {},
    }

    value.* = .{ .null = {} };
}

fn decodeValue(comptime T: type, value: std.json.Value) DecodeError!T {
    return switch (@typeInfo(T)) {
        .bool => switch (value) {
            .bool => |actual| actual,
            else => error.TypeMismatch,
        },
        .int => |int_info| decodeInt(T, int_info, value),
        .float => |float_info| decodeFloat(T, float_info, value),
        .optional => |optional_info| decodeOptional(optional_info.child, value),
        .pointer => |pointer_info| decodePointer(T, pointer_info, value),
        .@"enum" => decodeEnum(T, value),
        .@"struct" => |struct_info| decodeStruct(T, struct_info, value),
        else => error.InvalidParams,
    };
}

fn decodeStruct(
    comptime T: type,
    comptime struct_info: std.builtin.Type.Struct,
    value: std.json.Value,
) DecodeError!T {
    if (value != .object) return error.InvalidParams;

    var result: T = undefined;
    inline for (struct_info.fields) |field| {
        const maybe_field_value = value.object.get(field.name);
        @field(result, field.name) = try decodeField(field.type, maybe_field_value);
    }
    return result;
}

fn decodeField(comptime T: type, maybe_value: ?std.json.Value) DecodeError!T {
    if (@typeInfo(T) == .optional) {
        if (maybe_value == null) return null;
        return decodeValue(T, maybe_value.?);
    }

    const value = maybe_value orelse return error.InvalidParams;
    return decodeValue(T, value);
}

fn decodeInt(
    comptime T: type,
    comptime int_info: std.builtin.Type.Int,
    value: std.json.Value,
) DecodeError!T {
    _ = int_info;
    return switch (value) {
        .integer => |actual| std.math.cast(T, actual) orelse error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

fn decodeFloat(
    comptime T: type,
    comptime float_info: std.builtin.Type.Float,
    value: std.json.Value,
) DecodeError!T {
    _ = float_info;
    return switch (value) {
        .integer => |actual| @as(T, @floatFromInt(actual)),
        .float => |actual| @as(T, @floatCast(actual)),
        else => error.TypeMismatch,
    };
}

fn decodePointer(
    comptime T: type,
    comptime pointer_info: std.builtin.Type.Pointer,
    value: std.json.Value,
) DecodeError!T {
    if (pointer_info.size == .slice and pointer_info.child == u8) {
        return switch (value) {
            .string => |actual| actual,
            else => error.TypeMismatch,
        };
    }

    return error.InvalidParams;
}

fn decodeOptional(comptime T: type, value: std.json.Value) DecodeError!?T {
    if (value == .null) return null;
    return try decodeValue(T, value);
}

fn decodeEnum(comptime T: type, value: std.json.Value) DecodeError!T {
    return switch (value) {
        .string => |actual| std.meta.stringToEnum(T, actual) orelse error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

fn encodePointer(
    allocator: std.mem.Allocator,
    comptime pointer_info: std.builtin.Type.Pointer,
    value: anytype,
) !std.json.Value {
    switch (pointer_info.size) {
        .one => return try encodeResult(allocator, value.*),
        .slice => {
            if (pointer_info.child == u8) {
                return std.json.Value{ .string = try allocator.dupe(u8, value) };
            }
            return try encodeSlice(allocator, value);
        },
        else => return error.InvalidParams,
    }
}

fn encodeSlice(allocator: std.mem.Allocator, slice: anytype) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    for (slice) |item| {
        try array.append(try encodeResult(allocator, item));
    }

    return std.json.Value{ .array = array };
}

fn encodeStruct(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    var object = std.json.ObjectMap.init(allocator);
    errdefer object.deinit();

    const T = @TypeOf(value);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const key = try allocator.dupe(u8, field.name);
        errdefer allocator.free(key);

        const encoded = try encodeResult(allocator, @field(value, field.name));
        errdefer {
            var encoded_mut = encoded;
            deinitValue(allocator, &encoded_mut);
        }

        try object.put(key, encoded);
    }

    return std.json.Value{ .object = object };
}
