//! bench [--divide <d>]
//!
//! The Zig side of the workloads in director/spec/benchmarks.md. It prints one JSON
//! object per line, one line per phase, and the Swift side has to reach the same
//! file sizes: a difference means the port appended something different.
//!
//! Real numbers need a ReleaseFast build, and it refuses to give them otherwise.
//! `--divide <d>` divides every size by d, in any build, to check quickly that it
//! still works and that its file sizes are what `run` gets for the same operations.

const std = @import("std");
const builtin = @import("builtin");
const xitdb = @import("xitdb");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const HashInt = u160;
const FILE_ID: u64 = 0x0011223344556677;
const RUNS = 5;
const TMP_DIR = "out";
const TMP_PATH = "out/bench.db";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bench: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Workload = enum { map_insert, list_append, map_transactions };

const Result = struct { write_ms: f64, read_ms: f64, iterate_ms: f64, file_size: u64 };

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).toNanoseconds();
}

fn elapsedMs(from: i96, to: i96) f64 {
    return @as(f64, @floatFromInt(to - from)) / 1_000_000.0;
}

fn Bench(comptime kind: xitdb.DatabaseKind) type {
    return struct {
        const DB = xitdb.Database(kind, HashInt);
        const RW = DB.Cursor(.read_write);

        /// `[{"hash_map_get": {"value": HASH(key-<i>)}}, {"write": {"uint": i}}]`, for each i
        const PutKeys = struct {
            hashes: []const HashInt,
            start: u64,
            end: u64,

            pub fn run(self: PutKeys, cursor: *RW) !void {
                var i = self.start;
                while (i < self.end) : (i += 1) {
                    _ = try cursor.writePath(void, &.{
                        .{ .hash_map_get = .{ .value = self.hashes[@intCast(i)] } },
                        .{ .write = .{ .uint = i } },
                    });
                }
            }
        };

        /// `["array_list_append", {"write": {"uint": i}}]`, for each i
        const AppendValues = struct {
            n: u64,

            pub fn run(self: AppendValues, cursor: *RW) !void {
                var i: u64 = 0;
                while (i < self.n) : (i += 1) {
                    _ = try cursor.writePath(void, &.{
                        .array_list_append,
                        .{ .write = .{ .uint = i } },
                    });
                }
            }
        };

        fn writePhase(db: *DB, workload: Workload, n: u64, hashes: []const HashInt) !void {
            switch (workload) {
                .map_insert => {
                    _ = try db.rootCursor().writePath(PutKeys, &.{
                        .array_list_init,
                        .array_list_append,
                        .{ .hash_map_init = .{} },
                        .{ .ctx = .{ .hashes = hashes, .start = 0, .end = n } },
                    });
                },
                .list_append => {
                    _ = try db.rootCursor().writePath(AppendValues, &.{
                        .array_list_init,
                        .array_list_append,
                        .array_list_init,
                        .{ .ctx = .{ .n = n } },
                    });
                },
                .map_transactions => {
                    var j: u64 = 0;
                    while (j < n) : (j += 1) {
                        const last = try db.rootCursor().readPathSlot(void, &.{.{ .array_list_get = -1 }});
                        _ = try db.rootCursor().writePath(PutKeys, &.{
                            .array_list_init,
                            .array_list_append,
                            .{ .write = .{ .slot = last } },
                            .{ .hash_map_init = .{} },
                            .{ .ctx = .{ .hashes = hashes, .start = 10 * j, .end = 10 * j + 10 } },
                        });
                    }
                },
            }
        }

        fn readPhase(db: *DB, workload: Workload, n: u64, hashes: []const HashInt) !void {
            const moment = (try db.rootCursor().readPath(void, &.{.{ .array_list_get = -1 }})) orelse fail("there is no last moment", .{});
            switch (workload) {
                .map_insert, .map_transactions => {
                    const keys = if (workload == .map_insert) n else 10 * n;
                    var i: u64 = 0;
                    while (i < keys) : (i += 1) {
                        const value = (try moment.readPath(void, &.{.{ .hash_map_get = .{ .value = hashes[@intCast(i)] } }})) orelse fail("key {d} isn't there", .{i});
                        const got = try value.readUint();
                        if (got != i) fail("key {d} holds {d}", .{ i, got });
                    }
                },
                .list_append => {
                    var i: u64 = 0;
                    while (i < n) : (i += 1) {
                        const value = (try moment.readPath(void, &.{.{ .array_list_get = @as(i65, i) }})) orelse fail("index {d} isn't there", .{i});
                        const got = try value.readUint();
                        if (got != i) fail("index {d} holds {d}", .{ i, got });
                    }
                },
            }
        }

        fn iteratePhase(db: *DB, workload: Workload, n: u64, hashes: []const HashInt) !void {
            const moment = (try db.rootCursor().readPath(void, &.{.{ .array_list_get = -1 }})) orelse fail("there is no last moment", .{});
            var iter = try moment.iterator();
            var count: u64 = 0;
            switch (workload) {
                .map_insert, .map_transactions => {
                    const keys = if (workload == .map_insert) n else 10 * n;
                    var sum: u64 = 0;
                    while (try iter.next()) |entry| {
                        const pair = try entry.readKeyValuePair();
                        const value = try pair.value_cursor.readUint();
                        if (value >= keys) fail("an entry holds {d}, and there are only {d} keys", .{ value, keys });
                        if (pair.hash != hashes[@intCast(value)]) fail("the entry holding {d} doesn't have that key's hash", .{value});
                        count += 1;
                        sum += value;
                    }
                    if (count != keys) fail("{d} entries, and {d} keys were written", .{ count, keys });
                    if (sum != keys * (keys - 1) / 2) fail("the values add up to {d}", .{sum});
                },
                .list_append => {
                    while (try iter.next()) |element| {
                        const value = try element.readUint();
                        if (value != count) fail("element {d} holds {d}", .{ count, value });
                        count += 1;
                    }
                    if (count != n) fail("{d} elements, and {d} were written", .{ count, n });
                },
            }
        }

        fn once(io: Io, gpa: Allocator, workload: Workload, n: u64, hashes: []const HashInt) !Result {
            var buffer = Io.Writer.Allocating.init(gpa);
            defer buffer.deinit();

            const hash_id = xitdb.HashId.fromBytes("sha1");
            var db: DB = undefined;
            var file: ?Io.File = null;
            defer if (file) |f| f.close(io);
            switch (kind) {
                .memory => db = try DB.init(io, .{ .buffer = &buffer, .hash_id = hash_id, .file_id = FILE_ID }),
                .file => {
                    const f = try Io.Dir.cwd().createFile(io, TMP_PATH, .{ .read = true, .truncate = true });
                    file = f;
                    db = try DB.init(io, .{ .file = f, .fsync = false, .hash_id = hash_id, .file_id = FILE_ID });
                },
                .buffered_file => {
                    const f = try Io.Dir.cwd().createFile(io, TMP_PATH, .{ .read = true, .truncate = true });
                    file = f;
                    db = try DB.init(io, .{ .file = f, .buffer = &buffer, .fsync = false, .hash_id = hash_id, .file_id = FILE_ID });
                },
            }

            const write_start = nowNs(io);
            try writePhase(&db, workload, n, hashes);
            const write_end = nowNs(io);

            const file_size = try db.core.length();

            const read_start = nowNs(io);
            try readPhase(&db, workload, n, hashes);
            const read_end = nowNs(io);

            const iterate_start = nowNs(io);
            try iteratePhase(&db, workload, n, hashes);
            const iterate_end = nowNs(io);

            return .{
                .write_ms = elapsedMs(write_start, write_end),
                .read_ms = elapsedMs(read_start, read_end),
                .iterate_ms = elapsedMs(iterate_start, iterate_end),
                .file_size = file_size,
            };
        }

        fn run(io: Io, gpa: Allocator, w: *Io.Writer, workload: Workload, n: u64, hashes: []const HashInt) !void {
            var write_times: [RUNS]f64 = undefined;
            var read_times: [RUNS]f64 = undefined;
            var iterate_times: [RUNS]f64 = undefined;
            var file_size: u64 = 0;
            for (0..RUNS) |run_index| {
                const result = try once(io, gpa, workload, n, hashes);
                write_times[run_index] = result.write_ms;
                read_times[run_index] = result.read_ms;
                iterate_times[run_index] = result.iterate_ms;
                // the commit IDs are random, but the size can't depend on them
                if (run_index > 0 and result.file_size != file_size) fail("{s} gave file sizes {d} and {d}", .{ @tagName(workload), file_size, result.file_size });
                file_size = result.file_size;
            }
            std.mem.sort(f64, &write_times, {}, std.sort.asc(f64));
            std.mem.sort(f64, &read_times, {}, std.sort.asc(f64));
            std.mem.sort(f64, &iterate_times, {}, std.sort.asc(f64));
            try printLine(w, workload, "write", kind, n, write_times[RUNS / 2], file_size);
            try printLine(w, workload, "read", kind, n, read_times[RUNS / 2], file_size);
            try printLine(w, workload, "iterate", kind, n, iterate_times[RUNS / 2], file_size);
            try w.flush();
        }
    };
}

fn printLine(w: *Io.Writer, workload: Workload, phase: []const u8, kind: xitdb.DatabaseKind, n: u64, median_ms: f64, file_size: u64) !void {
    try w.print("{{\"workload\": \"{s}\", \"phase\": \"{s}\", \"kind\": \"{s}\", \"n\": {d}, \"median_ms\": {d:.3}, \"file_size\": {d}}}\n", .{
        @tagName(workload),
        phase,
        @tagName(kind),
        n,
        median_ms,
        file_size,
    });
}

fn computeHashes(gpa: Allocator, count: u64) ![]HashInt {
    const hashes = try gpa.alloc(HashInt, @intCast(count));
    var text: [32]u8 = undefined;
    for (hashes, 0..) |*hash, i| {
        const key = try std.fmt.bufPrint(&text, "key-{d}", .{i});
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(key, &digest, .{});
        hash.* = std.mem.readInt(HashInt, &digest, .big);
    }
    return hashes;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var divide: u64 = 1;
    if (args.len == 3 and std.mem.eql(u8, args[1], "--divide")) {
        divide = std.fmt.parseInt(u64, args[2], 10) catch fail("--divide needs a number", .{});
        if (divide == 0) fail("--divide can't be 0", .{});
    } else if (args.len != 1) {
        std.debug.print("usage: bench [--divide <d>]\n", .{});
        std.process.exit(2);
    }
    if (divide == 1 and builtin.mode != .fast) {
        fail("this is a {s} build, and its numbers would mean nothing. Build with -Doptimize=ReleaseFast, or use --divide to only check that it works", .{@tagName(builtin.mode)});
    }

    try Io.Dir.cwd().createDirPath(io, TMP_DIR);
    defer Io.Dir.cwd().deleteFile(io, TMP_PATH) catch {};

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout.interface;

    const map_n = 100_000 / divide;
    const map_file_n = 10_000 / divide;
    const list_n = 1_000_000 / divide;
    const transactions = 2_000 / divide;

    // every hash is computed before any clock starts
    const hashes = try computeHashes(gpa, @max(map_n, map_file_n, 10 * transactions));
    defer gpa.free(hashes);

    try Bench(.memory).run(io, gpa, w, .map_insert, map_n, hashes);
    try Bench(.buffered_file).run(io, gpa, w, .map_insert, map_n, hashes);
    try Bench(.file).run(io, gpa, w, .map_insert, map_file_n, hashes);
    try Bench(.memory).run(io, gpa, w, .list_append, list_n, hashes);
    try Bench(.buffered_file).run(io, gpa, w, .list_append, list_n, hashes);
    try Bench(.memory).run(io, gpa, w, .map_transactions, transactions, hashes);
    try Bench(.buffered_file).run(io, gpa, w, .map_transactions, transactions, hashes);
}
