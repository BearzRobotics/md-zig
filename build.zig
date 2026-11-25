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

    // Optional, experimental C interface (include/md.h): `zig build c-api`
    // installs libmd.a, libmd.so and md.h. The native module does not use it.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "md", .module = mod }},
        // System C toolchains link position independent executables.
        .pic = true,
    });
    const static_lib = b.addLibrary(.{ .name = "md", .linkage = .static, .root_module = capi_mod });
    // The code calls helpers (such as __zig_probe_stack) that a C toolchain's
    // runtime does not have.
    static_lib.bundle_compiler_rt = true;
    const shared_lib = b.addLibrary(.{ .name = "md", .linkage = .dynamic, .root_module = capi_mod });
    const c_api_step = b.step("c-api", "Build the experimental C library and header");
    c_api_step.dependOn(&b.addInstallArtifact(static_lib, .{}).step);
    c_api_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);
    c_api_step.dependOn(&b.addInstallFileWithDir(b.path("include/md.h"), .header, "md.h").step);

    // A C program that uses the static library: part of `zig build test`.
    const smoke = b.addExecutable(.{
        .name = "c-smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    smoke.root_module.addCSourceFile(.{ .file = b.path("test/c/smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    smoke.root_module.addIncludePath(b.path("include"));
    smoke.root_module.linkLibrary(static_lib);
    test_step.dependOn(&b.addRunArtifact(smoke).step);

    // The same program built by the system's C compiler against both installed
    // libraries, which is how a C user links them. Needs `cc`.
    const cc_step = b.step("test-cc", "Link the C smoke test with the system C compiler");
    for ([_]*std.Build.Step.Compile{ static_lib, shared_lib }) |library| {
        const cc = b.addSystemCommand(&.{ "cc", "-std=c11", "-Wall", "-Wextra", "-Werror" });
        cc.addPrefixedDirectoryArg("-I", b.path("include"));
        cc.addFileArg(b.path("test/c/smoke.c"));
        cc.addArtifactArg(library);
        // Lets the program built against the shared library find it.
        cc.addPrefixedDirectoryArg("-Wl,-rpath,", library.getEmittedBinDirectory());
        cc.addArg("-o");
        const program = cc.addOutputFileArg("c-smoke-cc");
        const run = std.Build.Step.Run.create(b, "run c-smoke-cc");
        run.addFileArg(program);
        cc_step.dependOn(&run.step);
    }
}
