const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xitdb = b.dependency("xitdb", .{}).module("xitdb");

    const run_exe = b.addExecutable(.{
        .name = "run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/run.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "xitdb", .module = xitdb }},
        }),
    });
    b.installArtifact(run_exe);

    const detcheck_exe = b.addExecutable(.{
        .name = "detcheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/detcheck.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(detcheck_exe);

    const manifest_exe = b.addExecutable(.{
        .name = "manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/manifest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(manifest_exe);

    const gen_exe = b.addExecutable(.{
        .name = "gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "xitdb", .module = xitdb }},
        }),
    });
    b.installArtifact(gen_exe);

    const coverage_exe = b.addExecutable(.{
        .name = "coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/coverage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(coverage_exe);
}
