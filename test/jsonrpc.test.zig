const std = @import("std");
const jsonrpc = @import("jsonrpc");

test "module exports all expected surfaces" {
    std.testing.refAllDecls(jsonrpc);
}
