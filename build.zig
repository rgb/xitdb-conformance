const std = @import("std");

/// what `run --version` and `dump --version` say they were built from: a checkout's commit, with "(with
/// uncommitted changes)" if its tracked files differ from it, and "unknown" where git can't say. That includes a
/// folder that isn't the top of a repository of its own, like the exports second-zig.sh makes inside this one, so
/// that git's search upward can't name this repository's commit for the original
fn commitOf(b: *std.Build, path: []const u8) []const u8 {
    var code: u8 = 0;
    const prefix = b.runAllowFail(&.{ "git", "-C", path, "rev-parse", "--show-prefix" }, &code, .ignore) catch return "unknown";
    if (std.mem.trim(u8, prefix, " \r\n").len != 0) return "unknown";
    const head = b.runAllowFail(&.{ "git", "-C", path, "rev-parse", "HEAD" }, &code, .ignore) catch return "unknown";
    const commit = b.dupe(std.mem.trim(u8, head, " \r\n"));
    const changes = b.runAllowFail(&.{ "git", "-C", path, "status", "--porcelain", "--untracked-files=no" }, &code, .ignore) catch
        return b.fmt("{s} (whether with uncommitted changes, unknown)", .{commit});
    if (std.mem.trim(u8, changes, " \r\n").len != 0) return b.fmt("{s} (with uncommitted changes)", .{commit});
    return commit;
}

/// the folder a package's build.zig is in, for git to be asked about
fn rootOf(b: *std.Build, package: *std.Build) []const u8 {
    const path = package.root.toString(b.allocator) catch return ".";
    return if (path.len == 0) "." else path;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xitdb_dep = b.dependency("xitdb", .{});
    const xitdb = xitdb_dep.module("xitdb");

    // asked of git every time zig build runs, so it follows the checkouts. A build from an export, which git can't
    // ask, gives the commits it was exported from, as second-zig.sh does
    const options = b.addOptions();
    options.addOption([]const u8, "xitdb_commit", b.option([]const u8, "xitdb-commit", "the original's commit, for a build git can't ask") orelse
        commitOf(b, rootOf(b, xitdb_dep.builder)));
    options.addOption([]const u8, "conformance_commit", b.option([]const u8, "conformance-commit", "this repository's commit, for a build git can't ask") orelse
        commitOf(b, rootOf(b, b)));
    const build_options = options.createModule();

    const run_exe = b.addExecutable(.{
        .name = "run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/run.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "xitdb", .module = xitdb }, .{ .name = "build_options", .module = build_options } },
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

    const longscripts_exe = b.addExecutable(.{
        .name = "longscripts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/longscripts.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(longscripts_exe);

    const coverage_exe = b.addExecutable(.{
        .name = "coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/coverage.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(coverage_exe);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "xitdb", .module = xitdb }},
        }),
    });
    b.installArtifact(bench_exe);

    const dump_exe = b.addExecutable(.{
        .name = "dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "xitdb", .module = xitdb }, .{ .name = "build_options", .module = build_options } },
        }),
    });
    b.installArtifact(dump_exe);

    const wrappers_exe = b.addExecutable(.{
        .name = "undefined-wrappers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/undefined/wrappers.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "xitdb", .module = xitdb }},
        }),
    });
    b.installArtifact(wrappers_exe);
}
