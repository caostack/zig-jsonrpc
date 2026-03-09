const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    const mod = b.addModule("jsonrpc", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
    });

    const test_files = [_][]const u8{
        "test/types.test.zig",
        "test/codec.test.zig",
        "test/serde.test.zig",
        "test/router.test.zig",
        "test/server.test.zig",
        "test/client.test.zig",
        "test/compatibility.test.zig",
        "test/property.test.zig",
        "test/jsonrpc.test.zig",
    };

    const test_step = b.step("test", "Run tests");
    inline for (test_files) |path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .imports = &.{
                    .{ .name = "jsonrpc", .module = mod },
                },
            }),
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    const fmt_check = b.addSystemCommand(&.{
        "zig",
        "fmt",
        "--check",
        "build.zig",
        "src",
        "test",
    });

    const quality_step = b.step("quality", "Run quality gate checks");
    quality_step.dependOn(&fmt_check.step);
    quality_step.dependOn(b.getInstallStep());
    quality_step.dependOn(test_step);
}
