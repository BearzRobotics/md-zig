//! md-zig build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as @import("md").
    const mod = b.addModule("md", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The specification's examples, compared byte for byte (src/tests.zig).
    mod.addAnonymousImport("spec-0.31.2.json", .{ .root_source_file = b.path("test/fixtures/spec-0.31.2.json") });

    mod.addAnonymousImport("gfm-extensions.json", .{ .root_source_file = b.path("test/fixtures/gfm-extensions.json") });

    // A small renderer for trying the library out: `zig build` then `zig-out/bin/mdcat FILE`.
    const mdcat = b.addExecutable(.{
        .name = "mdcat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/mdcat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "md", .module = mod }},
        }),
    });
    b.installArtifact(mdcat);

    const test_step = b.step("test", "Run unit and conformance tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}
