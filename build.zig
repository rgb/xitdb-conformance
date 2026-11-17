const std = @import("std");

/// what `run --version` and `dump --version` say they were built from, as a file of two constants: a checkout's
/// commit, with "(with uncommitted changes)" if its tracked files differ from it, and "unknown" where git can't say.
/// That includes a folder that isn't the top of a repository of its own, like the exports second-zig.sh makes inside
/// this one, so that git's search upward can't name this repository's commit for the original. A commit given to the
/// build is used as it is
const DESCRIBE =
    \\commit_of() { # folder, commit given
    \\    if [ -n "$2" ]; then printf '%s' "$2"; return; fi
    \\    prefix=$(git -C "$1" rev-parse --show-prefix 2> /dev/null) || { printf unknown; return; }
    \\    if [ -n "$prefix" ]; then printf unknown; return; fi
    \\    head=$(git -C "$1" rev-parse HEAD 2> /dev/null) || { printf unknown; return; }
    \\    if ! changes=$(git -C "$1" status --porcelain --untracked-files=no 2> /dev/null); then
    \\        printf '%s (whether with uncommitted changes, unknown)' "$head"
    \\    elif [ -n "$changes" ]; then
    \\        printf '%s (with uncommitted changes)' "$head"
    \\    else
    \\        printf '%s' "$head"
    \\    fi
    \\}
    \\printf 'pub const xitdb_commit = "%s";\npub const conformance_commit = "%s";\n' "$(commit_of "$1" "$2")" "$(commit_of "$3" "$4")"
;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xitdb_dep = b.dependency("xitdb", .{});
    const xitdb = xitdb_dep.module("xitdb");

    // asked of git at every build, by a step whose result is never kept, as git's answer changes without build.zig
    // changing, which is all the build's own cache would see. A build from an export, which git can't ask, is given
    // the commits it was exported from, as second-zig.sh does
    const describe = b.addSystemCommand(&.{ "sh", "-c", DESCRIBE, "describe" });
    describe.addDirectoryArg(xitdb_dep.path("."));
    describe.addArg(b.option([]const u8, "xitdb-commit", "the original's commit, for a build git can't ask") orelse "");
    describe.addDirectoryArg(b.path("."));
    describe.addArg(b.option([]const u8, "conformance-commit", "this repository's commit, for a build git can't ask") orelse "");
    describe.has_side_effects = true;
    const build_options = b.createModule(.{ .root_source_file = describe.captureStdOut(.{ .basename = "build_options.zig" }) });

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
