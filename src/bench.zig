//! bench [--divide <d>] [--only <workload>]
//!
//! The Zig side of the workloads in director/spec/benchmarks.md. It prints one JSON
//! object per line, one line per phase, and the Swift side has to reach the same
//! file sizes: a difference means the port appended something different.
//!
//! Real numbers need a ReleaseFast build, and it refuses to give them otherwise.
//! `--divide <d>` divides every size by d, in any build, to check quickly that it
//! still works and that its file sizes are what `run` gets for the same operations.
//! `--only <workload>` leaves out the others.

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
// what map_compact compacts into, and replicate's replica
const TARGET_PATH = "out/bench-target.db";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bench: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Workload = enum { map_insert, list_append, map_transactions, linked_append, sorted_insert, map_compact, replicate };

/// what's worked out before any clock starts
const Inputs = struct {
    hashes: []const HashInt,
    // the keys of a sorted map, `key-<i>`
    keys: []const []const u8,
};

/// longer than any key here, which is what the spec says to read a key into
const KEY_BUFFER_SIZE = 16;

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

        /// `["linked_array_list_append", {"write": {"uint": i}}]`, for each i
        const AppendLinkedValues = struct {
            n: u64,

            pub fn run(self: AppendLinkedValues, cursor: *RW) !void {
                var i: u64 = 0;
                while (i < self.n) : (i += 1) {
                    _ = try cursor.writePath(void, &.{
                        .linked_array_list_append,
                        .{ .write = .{ .uint = i } },
                    });
                }
            }
        };

        /// `[{"sorted_map_get": {"value": "key-<i>"}}, {"write": {"uint": i}}]`, for each i
        const PutSortedKeys = struct {
            keys: []const []const u8,
            n: u64,

            pub fn run(self: PutSortedKeys, cursor: *RW) !void {
                var i: u64 = 0;
                while (i < self.n) : (i += 1) {
                    _ = try cursor.writePath(void, &.{
                        .{ .sorted_map_get = .{ .value = self.keys[@intCast(i)] } },
                        .{ .write = .{ .uint = i } },
                    });
                }
            }
        };

        /// map_transactions' transactions from `from` up to `to`
        fn putTransactions(db: *DB, hashes: []const HashInt, from: u64, to: u64) !void {
            var j = from;
            while (j < to) : (j += 1) {
                const last = try db.rootCursor().readPathSlot(void, &.{.{ .array_list_get = -1 }});
                _ = try db.rootCursor().writePath(PutKeys, &.{
                    .array_list_init,
                    .array_list_append,
                    .{ .write = .{ .slot = last } },
                    .{ .hash_map_init = .{} },
                    .{ .ctx = .{ .hashes = hashes, .start = 10 * j, .end = 10 * j + 10 } },
                });
            }
        }

        fn writePhase(db: *DB, workload: Workload, n: u64, inputs: Inputs) !void {
            const hashes = inputs.hashes;
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
                .map_transactions => try putTransactions(db, hashes, 0, n),
                .linked_append => {
                    _ = try db.rootCursor().writePath(AppendLinkedValues, &.{
                        .array_list_init,
                        .array_list_append,
                        .linked_array_list_init,
                        .{ .ctx = .{ .n = n } },
                    });
                },
                .sorted_insert => {
                    _ = try db.rootCursor().writePath(PutSortedKeys, &.{
                        .array_list_init,
                        .array_list_append,
                        .{ .sorted_map_init = .{} },
                        .{ .ctx = .{ .keys = inputs.keys, .n = n } },
                    });
                },
                // their write phases are a compaction, which is compactOnce, and a sync,
                // which is replicateOnce
                .map_compact, .replicate => unreachable,
            }
        }

        fn readPhase(db: *DB, workload: Workload, n: u64, inputs: Inputs) !void {
            const hashes = inputs.hashes;
            const moment = (try db.rootCursor().readPath(void, &.{.{ .array_list_get = -1 }})) orelse fail("there is no last moment", .{});
            switch (workload) {
                .map_insert, .map_transactions, .map_compact => {
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
                .linked_append => {
                    var i: u64 = 0;
                    while (i < n) : (i += 1) {
                        const value = (try moment.readPath(void, &.{.{ .linked_array_list_get = @as(i65, i) }})) orelse fail("index {d} isn't there", .{i});
                        const got = try value.readUint();
                        if (got != i) fail("index {d} holds {d}", .{ i, got });
                    }
                },
                .sorted_insert => {
                    var i: u64 = 0;
                    while (i < n) : (i += 1) {
                        const value = (try moment.readPath(void, &.{.{ .sorted_map_get = .{ .value = inputs.keys[@intCast(i)] } }})) orelse fail("key {d} isn't there", .{i});
                        const got = try value.readUint();
                        if (got != i) fail("key {d} holds {d}", .{ i, got });
                    }
                },
                // its read phase is a sync, which is replicateOnce
                .replicate => unreachable,
            }
        }

        fn iteratePhase(db: *DB, workload: Workload, n: u64, inputs: Inputs) !void {
            const hashes = inputs.hashes;
            const moment = (try db.rootCursor().readPath(void, &.{.{ .array_list_get = -1 }})) orelse fail("there is no last moment", .{});
            var iter = try moment.iterator();
            var count: u64 = 0;
            switch (workload) {
                .map_insert, .map_transactions, .map_compact => {
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
                .list_append, .linked_append => {
                    while (try iter.next()) |element| {
                        const value = try element.readUint();
                        if (value != count) fail("element {d} holds {d}", .{ count, value });
                        count += 1;
                    }
                    if (count != n) fail("{d} elements, and {d} were written", .{ count, n });
                },
                .sorted_insert => {
                    // the key before this one is in the buffer this one isn't read into
                    var buffers: [2][KEY_BUFFER_SIZE]u8 = undefined;
                    var previous: []const u8 = &.{};
                    while (try iter.next()) |entry| {
                        const pair = try entry.readKeyValuePair();
                        const value = try pair.value_cursor.readUint();
                        if (value >= n) fail("an entry holds {d}, and there are only {d} keys", .{ value, n });
                        const key = try pair.key_cursor.readBytes(&buffers[@intCast(count % 2)]);
                        if (!std.mem.eql(u8, key, inputs.keys[@intCast(value)])) fail("the entry holding {d} has the key {s}", .{ value, key });
                        if (count > 0 and std.mem.order(u8, key, previous) != .gt) fail("the key {s} comes after the key {s}", .{ key, previous });
                        previous = key;
                        count += 1;
                    }
                    if (count != n) fail("{d} entries, and {d} keys were written", .{ count, n });
                },
                // replicateOnce iterates as map_transactions does, over its t + 10 transactions
                .replicate => unreachable,
            }
        }

        /// what makes a new database of this kind. the file, if it has one, is the caller's to close
        fn newOpts(io: Io, path: []const u8, buffer: *Io.Writer.Allocating, file: *?Io.File) !xitdb.InitOpts(kind) {
            const hash_id = xitdb.HashId.fromBytes("sha1");
            switch (kind) {
                .memory => return .{ .buffer = buffer, .hash_id = hash_id, .file_id = FILE_ID },
                .file => {
                    const f = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
                    file.* = f;
                    return .{ .file = f, .fsync = false, .hash_id = hash_id, .file_id = FILE_ID };
                },
                .buffered_file => {
                    const f = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
                    file.* = f;
                    return .{ .file = f, .buffer = buffer, .fsync = false, .hash_id = hash_id, .file_id = FILE_ID };
                },
            }
        }

        /// the read and iterate phases, once the write phase has given this file size and time
        fn finish(io: Io, db: *DB, workload: Workload, n: u64, inputs: Inputs, write_ms: f64) !Result {
            const file_size = try db.core.length();

            const read_start = nowNs(io);
            try readPhase(db, workload, n, inputs);
            const read_end = nowNs(io);

            const iterate_start = nowNs(io);
            try iteratePhase(db, workload, n, inputs);
            const iterate_end = nowNs(io);

            return .{
                .write_ms = write_ms,
                .read_ms = elapsedMs(read_start, read_end),
                .iterate_ms = elapsedMs(iterate_start, iterate_end),
                .file_size = file_size,
            };
        }

        /// map_compact, from a source that's ready. the clock covers the call alone, and the
        /// phases after it are on the target
        fn compactOnce(io: Io, gpa: Allocator, source: *DB, n: u64, inputs: Inputs) !Result {
            var buffer = Io.Writer.Allocating.init(gpa);
            defer buffer.deinit();
            var file: ?Io.File = null;
            defer if (file) |f| f.close(io);
            const opts = try newOpts(io, TARGET_PATH, &buffer, &file);

            // a new one each run, as a run starts from nothing, so that growing it is on the clock
            var offset_map = std.AutoHashMap(u64, u64).init(gpa);
            defer offset_map.deinit();

            const write_start = nowNs(io);
            var target = try source.compact(kind, opts, &offset_map);
            const write_end = nowNs(io);

            return finish(io, &target, .map_compact, n, inputs, elapsedMs(write_start, write_end));
        }

        /// replicate: a source of n + 10 transactions is ready, and a full sync brings a new
        /// replica up to the first n, which is the write phase. an incremental sync brings it
        /// the other 10, which is the read phase. the bytes go through memory.
        fn replicateOnce(io: Io, gpa: Allocator, n: u64, inputs: Inputs) !Result {
            var source_buffer = Io.Writer.Allocating.init(gpa);
            defer source_buffer.deinit();
            var source_file: ?Io.File = null;
            defer if (source_file) |f| f.close(io);
            var source = try DB.init(io, try newOpts(io, TMP_PATH, &source_buffer, &source_file));
            try putTransactions(&source, inputs.hashes, 0, n);
            const size_t = try source.committedSize();
            try putTransactions(&source, inputs.hashes, n, n + 10);

            var replica_buffer = Io.Writer.Allocating.init(gpa);
            defer replica_buffer.deinit();
            var replica_file: ?Io.File = null;
            defer if (replica_file) |f| f.close(io);
            var replica = try DB.init(io, try newOpts(io, TARGET_PATH, &replica_buffer, &replica_file));

            // both start with nothing in them, so that growing them is on the clock
            var full_sync = Io.Writer.Allocating.init(gpa);
            defer full_sync.deinit();
            var incremental_sync = Io.Writer.Allocating.init(gpa);
            defer incremental_sync.deinit();

            const write_start = nowNs(io);
            try source.readCommitted(0, size_t, &full_sync.writer);
            var full_reader = Io.Reader.fixed(full_sync.written());
            try replica.applyReplicated(0, &full_reader, size_t);
            const write_end = nowNs(io);

            const after_full = try replica.committedSize();
            if (after_full != size_t) fail("the full sync left a committed size of {d}, and it should be {d}", .{ after_full, size_t });

            const read_start = nowNs(io);
            const start = try source.replicationStart(try replica.replicaState());
            const end = try source.committedSize();
            try source.readCommitted(start, end, &incremental_sync.writer);
            var incremental_reader = Io.Reader.fixed(incremental_sync.written());
            try replica.applyReplicated(start, &incremental_reader, end - start);
            const read_end = nowNs(io);

            if (start != size_t) fail("the incremental sync starts at {d}, and it should be {d}", .{ start, size_t });
            const after_incremental = try replica.committedSize();
            if (after_incremental != end) fail("the incremental sync left a committed size of {d}, and it should be {d}", .{ after_incremental, end });
            const file_size = try replica.core.length();
            if (file_size != end) fail("the replica's file is {d} bytes, and the source has {d} committed", .{ file_size, end });

            const iterate_start = nowNs(io);
            try iteratePhase(&replica, .map_transactions, n + 10, inputs);
            const iterate_end = nowNs(io);

            return .{
                .write_ms = elapsedMs(write_start, write_end),
                .read_ms = elapsedMs(read_start, read_end),
                .iterate_ms = elapsedMs(iterate_start, iterate_end),
                .file_size = file_size,
            };
        }

        fn once(io: Io, gpa: Allocator, workload: Workload, n: u64, inputs: Inputs) !Result {
            if (workload == .replicate) return replicateOnce(io, gpa, n, inputs);

            var buffer = Io.Writer.Allocating.init(gpa);
            defer buffer.deinit();
            var file: ?Io.File = null;
            defer if (file) |f| f.close(io);
            var db = try DB.init(io, try newOpts(io, TMP_PATH, &buffer, &file));

            if (workload == .map_compact) {
                try writePhase(&db, .map_transactions, n, inputs);
                return compactOnce(io, gpa, &db, n, inputs);
            }

            const write_start = nowNs(io);
            try writePhase(&db, workload, n, inputs);
            const write_end = nowNs(io);

            return finish(io, &db, workload, n, inputs, elapsedMs(write_start, write_end));
        }

        fn run(io: Io, gpa: Allocator, w: *Io.Writer, only: ?Workload, workload: Workload, n: u64, inputs: Inputs) !void {
            if (only != null and only.? != workload) return;
            var write_times: [RUNS]f64 = undefined;
            var read_times: [RUNS]f64 = undefined;
            var iterate_times: [RUNS]f64 = undefined;
            var file_size: u64 = 0;
            for (0..RUNS) |run_index| {
                const result = try once(io, gpa, workload, n, inputs);
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
    try w.print("{{\"workload\": \"{s}\", \"phase\": \"{s}\", \"kind\": \"{s}\", \"n\": {d}, \"median_ms\": {d:.6}, \"file_size\": {d}}}\n", .{
        @tagName(workload),
        phase,
        @tagName(kind),
        n,
        median_ms,
        file_size,
    });
}

fn computeKeys(arena: Allocator, count: u64) ![]const []const u8 {
    const keys = try arena.alloc([]const u8, @intCast(count));
    for (keys, 0..) |*key, i| {
        key.* = try std.fmt.allocPrint(arena, "key-{d}", .{i});
        if (key.len > KEY_BUFFER_SIZE) fail("the key {s} is longer than what the spec reads it into", .{key.*});
    }
    return keys;
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
    var only: ?Workload = null;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 2) {
        if (arg_index + 1 >= args.len) {
            std.debug.print("usage: bench [--divide <d>] [--only <workload>]\n", .{});
            std.process.exit(2);
        }
        if (std.mem.eql(u8, args[arg_index], "--divide")) {
            divide = std.fmt.parseInt(u64, args[arg_index + 1], 10) catch fail("--divide needs a number", .{});
            if (divide == 0) fail("--divide can't be 0", .{});
        } else if (std.mem.eql(u8, args[arg_index], "--only")) {
            only = std.meta.stringToEnum(Workload, args[arg_index + 1]) orelse fail("{s} isn't a workload", .{args[arg_index + 1]});
        } else {
            std.debug.print("usage: bench [--divide <d>] [--only <workload>]\n", .{});
            std.process.exit(2);
        }
    }
    if (divide == 1 and builtin.mode != .fast) {
        fail("this is a {s} build, and its numbers would mean nothing. Build with -Doptimize=ReleaseFast, or use --divide to only check that it works", .{@tagName(builtin.mode)});
    }

    try Io.Dir.cwd().createDirPath(io, TMP_DIR);
    defer Io.Dir.cwd().deleteFile(io, TMP_PATH) catch {};
    defer Io.Dir.cwd().deleteFile(io, TARGET_PATH) catch {};

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout.interface;

    const map_n = 100_000 / divide;
    const map_file_n = 10_000 / divide;
    const list_n = 1_000_000 / divide;
    const transactions = 2_000 / divide;
    const linked_n = 100_000 / divide;
    const linked_file_n = 10_000 / divide;
    const sorted_n = 100_000 / divide;
    const sorted_file_n = 10_000 / divide;
    const compact_n = 2_000 / divide;
    // at least one, as a compaction with no moment to read has nothing to check
    const compact_file_n = @max(200 / divide, 1);
    const replicate_n = 2_000 / divide;
    const replicate_file_n = @max(200 / divide, 1);

    // every hash and key is computed before any clock starts
    const hashes = try computeHashes(gpa, @max(map_n, map_file_n, 10 * transactions, 10 * compact_n, 10 * compact_file_n, 10 * (replicate_n + 10), 10 * (replicate_file_n + 10)));
    defer gpa.free(hashes);
    const inputs: Inputs = .{ .hashes = hashes, .keys = try computeKeys(arena, @max(sorted_n, sorted_file_n)) };

    try Bench(.memory).run(io, gpa, w, only, .map_insert, map_n, inputs);
    try Bench(.buffered_file).run(io, gpa, w, only, .map_insert, map_n, inputs);
    try Bench(.file).run(io, gpa, w, only, .map_insert, map_file_n, inputs);
    try Bench(.memory).run(io, gpa, w, only, .list_append, list_n, inputs);
    try Bench(.buffered_file).run(io, gpa, w, only, .list_append, list_n, inputs);
    try Bench(.memory).run(io, gpa, w, only, .map_transactions, transactions, inputs);
    try Bench(.buffered_file).run(io, gpa, w, only, .map_transactions, transactions, inputs);
    try Bench(.memory).run(io, gpa, w, only, .linked_append, linked_n, inputs);
    try Bench(.buffered_file).run(io, gpa, w, only, .linked_append, linked_n, inputs);
    try Bench(.file).run(io, gpa, w, only, .linked_append, linked_file_n, inputs);
    try Bench(.memory).run(io, gpa, w, only, .sorted_insert, sorted_n, inputs);
    try Bench(.buffered_file).run(io, gpa, w, only, .sorted_insert, sorted_n, inputs);
    try Bench(.file).run(io, gpa, w, only, .sorted_insert, sorted_file_n, inputs);
    try Bench(.memory).run(io, gpa, w, only, .map_compact, compact_n, inputs);
    try Bench(.buffered_file).run(io, gpa, w, only, .map_compact, compact_n, inputs);
    try Bench(.file).run(io, gpa, w, only, .map_compact, compact_file_n, inputs);
    try Bench(.memory).run(io, gpa, w, only, .replicate, replicate_n, inputs);
    try Bench(.buffered_file).run(io, gpa, w, only, .replicate, replicate_n, inputs);
    try Bench(.file).run(io, gpa, w, only, .replicate, replicate_file_n, inputs);
}
