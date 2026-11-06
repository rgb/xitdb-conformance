//! detcheck [--ignore-reads] <a.db> <b.db>
//!
//! Checks that two runs of one script produced the same file apart from the
//! random commit IDs. Each file is read together with its sidecar. With
//! --ignore-reads the two scripts can differ in ops that neither commit nor change
//! the committed size, so it's a check that those changed nothing. It fails unless:
//!
//! 1. the sidecars agree on the file ID, the sizes, and which ops committed;
//! 2. each sidecar's commit IDs are the ones in its file's trailers;
//! 3. every checksum in both files recomputes from the bytes around it;
//! 4. the files differ only inside the commit ID and checksum of each trailer;
//! 5. writing b's commit IDs into a and recomputing the checksums gives exactly b.
//!
//! A commit's trailer can be gone from the file by the end, if the file's root
//! header was set back and a later transaction wrote over it. Only those still
//! there are checked, including any past the last committed size.
//!
//! The last one is what the Swift runner relies on: the sidecar's commit IDs are
//! all it takes to reproduce a file.
//!
//! A script with several databases has a sidecar that lists the trailers in each one's
//! file, and the same goes for each of them, read from next to <a.db> and <b.db>. What
//! one of those holds can have come from another through replication, so the list is
//! what says where its commit IDs are, rather than which ops committed. A trailer
//! that a failed sync cut short is only compared as far as it goes.

const std = @import("std");

const Json = std.json.Value;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SIDECAR_SUFFIX = ".sidecar.json";

// offsets from file-format.md: the file ID is in the database header, the committed
// size is in the root header, and the trailer is root slot, commit ID, checksum.
const FILE_ID_OFFSET = 12;
const ROOT_HEADER_FILE_SIZE_OFFSET = 29;
const INITIAL_TRAILER_END = 62;
const TRAILER_SIZE = 25;
const TRAILER_COMMIT_ID_OFFSET = 9;
const TRAILER_CHECKSUM_OFFSET = 17;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("detcheck: FAILED: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Sidecar = struct {
    file_id: u64,
    initial_size: u64,
    file_size: u64,
    ops: []const Op,
    // only in a script with several
    databases: []const Database = &.{},

    const Op = struct {
        // null while the database is closed
        committed_size: ?u64,
        commit_id: ?u64,
        db: ?[]const u8 = null,
    };

    const Database = struct {
        name: []const u8,
        file_id: u64,
        file_size: u64,
        trailers: []const Trailer,
    };

    const Trailer = struct {
        position: u64,
        commit_id: u64,
        file_id: u64,
    };
};

fn field(obj: std.json.ObjectMap, name: []const u8, path: []const u8) Json {
    return obj.get(name) orelse fail("{s}: no \"{s}\"", .{ path, name });
}

fn parseU64(v: Json, path: []const u8) u64 {
    if (v != .number_string) fail("{s}: expected an integer", .{path});
    return std.fmt.parseInt(u64, v.number_string, 10) catch fail("{s}: bad integer {s}", .{ path, v.number_string });
}

fn parseHexId(v: Json, path: []const u8) u64 {
    if (v != .string or v.string.len != 16) fail("{s}: expected 16 hex digits", .{path});
    return std.fmt.parseInt(u64, v.string, 16) catch fail("{s}: bad hex {s}", .{ path, v.string });
}

fn readSidecar(io: Io, arena: Allocator, db_path: []const u8) !Sidecar {
    const path = try std.mem.concat(arena, u8, &.{ db_path, SIDECAR_SUFFIX });
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const parsed = try std.json.parseFromSliceLeaky(Json, arena, text, .{ .parse_numbers = false });
    if (parsed != .object) fail("{s}: expected an object", .{path});
    const obj = parsed.object;

    const ops_json = field(obj, "ops", path);
    if (ops_json != .array) fail("{s}: ops must be an array", .{path});
    const ops = try arena.alloc(Sidecar.Op, ops_json.array.items.len);
    for (ops_json.array.items, ops) |item, *op| {
        if (item != .object) fail("{s}: an op must be an object", .{path});
        const commit_id = field(item.object, "commit_id", path);
        const committed_size = field(item.object, "committed_size", path);
        op.* = .{
            .committed_size = if (committed_size == .null) null else parseU64(committed_size, path),
            .commit_id = if (commit_id == .null) null else parseHexId(commit_id, path),
            .db = if (item.object.get("db")) |db| db.string else null,
        };
    }

    var databases: std.ArrayList(Sidecar.Database) = .empty;
    if (obj.get("databases")) |value| {
        var iter = value.object.iterator();
        while (iter.next()) |entry| {
            const db = entry.value_ptr.object;
            const items = field(db, "trailers", path).array.items;
            const trailers = try arena.alloc(Sidecar.Trailer, items.len);
            for (items, trailers) |item, *trailer| {
                trailer.* = .{
                    .position = parseU64(field(item.object, "position", path), path),
                    .commit_id = parseHexId(field(item.object, "commit_id", path), path),
                    .file_id = parseHexId(field(item.object, "file_id", path), path),
                };
            }
            try databases.append(arena, .{
                .name = entry.key_ptr.*,
                .file_id = parseHexId(field(db, "file_id", path), path),
                .file_size = parseU64(field(db, "file_size", path), path),
                .trailers = trailers,
            });
        }
    }

    return .{
        .file_id = parseHexId(field(obj, "file_id", path), path),
        .initial_size = parseU64(field(obj, "initial_size", path), path),
        .file_size = parseU64(field(obj, "file_size", path), path),
        .ops = ops,
        .databases = databases.items,
    };
}

/// <a>.<name>.db, next to <a>.db
fn pathOf(arena: Allocator, main_path: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "main")) return main_path;
    const stem = if (std.mem.endsWith(u8, main_path, ".db")) main_path[0 .. main_path.len - 3] else main_path;
    return std.mem.concat(arena, u8, &.{ stem, ".", name, ".db" });
}

fn checkSeveral(io: Io, arena: Allocator, path_a: []const u8, path_b: []const u8, side_a: Sidecar, side_b: Sidecar) !void {
    if (side_a.ops.len != side_b.ops.len) fail("op counts differ", .{});
    if (side_a.databases.len != side_b.databases.len) fail("database counts differ", .{});
    var commits: usize = 0;
    for (side_a.ops, side_b.ops, 0..) |op_a, op_b, i| {
        if (!std.mem.eql(u8, op_a.db orelse "main", op_b.db orelse "main")) fail("op {d}: they're about different databases", .{i});
        if (!std.meta.eql(op_a.committed_size, op_b.committed_size)) fail("op {d}: committed sizes differ", .{i});
        if ((op_a.commit_id == null) != (op_b.commit_id == null)) fail("op {d}: only one run committed", .{i});
        if (op_a.commit_id != null) commits += 1;
    }

    var total: u64 = 0;
    var differing: u64 = 0;
    var compared: u64 = 0;
    for (side_a.databases, side_b.databases) |db_a, db_b| {
        if (!std.mem.eql(u8, db_a.name, db_b.name)) fail("the databases are {s} and {s}", .{ db_a.name, db_b.name });
        const name = db_a.name;
        if (db_a.file_id != db_b.file_id) fail("{s}: file IDs differ", .{name});
        if (db_a.file_size != db_b.file_size) fail("{s}: file sizes differ: {d} and {d}", .{ name, db_a.file_size, db_b.file_size });
        if (db_a.trailers.len != db_b.trailers.len) fail("{s}: they have different numbers of trailers", .{name});

        const file_a = try pathOf(arena, path_a, name);
        const file_b = try pathOf(arena, path_b, name);
        const a = try Io.Dir.cwd().readFileAlloc(io, file_a, arena, .unlimited);
        const b = try Io.Dir.cwd().readFileAlloc(io, file_b, arena, .unlimited);
        if (a.len != db_a.file_size) fail("{s} is {d} bytes, but its sidecar says {d}", .{ file_a, a.len, db_a.file_size });
        if (b.len != db_b.file_size) fail("{s} is {d} bytes, but its sidecar says {d}", .{ file_b, b.len, db_b.file_size });
        if (a.len >= FILE_ID_OFFSET + 8) {
            if (readBe64(a, FILE_ID_OFFSET) != db_a.file_id) fail("{s}: the file ID is not the sidecar's", .{file_a});
            if (readBe64(b, FILE_ID_OFFSET) != db_b.file_id) fail("{s}: the file ID is not the sidecar's", .{file_b});
        }

        const may_differ = try arena.alloc(bool, a.len);
        @memset(may_differ, false);
        const patched = try arena.dupe(u8, a);

        for (db_a.trailers, db_b.trailers) |trailer_a, trailer_b| {
            if (trailer_a.position != trailer_b.position) fail("{s}: trailers at {d} and {d}", .{ name, trailer_a.position, trailer_b.position });
            if (trailer_a.file_id != trailer_b.file_id) fail("{s}: the trailer at {d} has two file IDs", .{ name, trailer_a.position });
            const position = trailer_a.position;
            const whole = position + TRAILER_SIZE <= a.len;
            if (whole) {
                if (readBe64(a, position + TRAILER_COMMIT_ID_OFFSET) != trailer_a.commit_id) fail("{s}: no commit ID {x:0>16} at {d}", .{ file_a, trailer_a.commit_id, position });
                if (readBe64(b, position + TRAILER_COMMIT_ID_OFFSET) != trailer_b.commit_id) fail("{s}: no commit ID {x:0>16} at {d}", .{ file_b, trailer_b.commit_id, position });
                checkTrailer(file_a, a, trailer_a.file_id, position + TRAILER_SIZE);
                checkTrailer(file_b, b, trailer_b.file_id, position + TRAILER_SIZE);
            }
            compared += 1;

            // a trailer can be cut short by a sync that stopped part way
            const start: usize = @intCast(position + TRAILER_COMMIT_ID_OFFSET);
            const stop: usize = @intCast(@min(position + TRAILER_SIZE, a.len));
            if (start >= stop) continue;
            @memset(may_differ[start..stop], true);

            var tail: [16]u8 = undefined;
            std.mem.writeInt(u64, tail[0..8], trailer_b.commit_id, .big);
            const offset: usize = @intCast(position);
            std.mem.writeInt(u64, tail[8..16], computeChecksum(trailer_a.file_id, position, patched[offset..][0..9], trailer_b.commit_id), .big);
            @memcpy(patched[start..stop], tail[0 .. stop - start]);
        }

        for (a, b, may_differ, 0..) |byte_a, byte_b, allowed, offset| {
            if (byte_a == byte_b) continue;
            if (!allowed) fail("{s}: byte {d} differs ({x:0>2} and {x:0>2}), and it isn't part of a trailer's commit ID or checksum", .{ name, offset, byte_a, byte_b });
            differing += 1;
        }
        if (!std.mem.eql(u8, patched, b)) {
            const offset = std.mem.findDiff(u8, patched, b).?;
            fail("{s}: a with b's commit IDs differs from b at byte {d}", .{ name, offset });
        }
        total += a.len;
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout.interface.print("ok: {d} databases, {d} bytes, {d} commits, {d} trailers, {d} of their bytes differ, 0 other bytes differ, a + b's commit IDs == b\n", .{
        side_a.databases.len,
        total,
        commits,
        compared,
        differing,
    });
    try stdout.interface.flush();
}

/// the ops that did something to the file, for comparing scripts that only differ in reads
fn withoutReads(arena: Allocator, sidecar: Sidecar) !Sidecar {
    var kept: std.ArrayList(Sidecar.Op) = .empty;
    var previous: ?u64 = sidecar.initial_size;
    for (sidecar.ops) |op| {
        if (op.commit_id == null and std.meta.eql(op.committed_size, previous)) continue;
        try kept.append(arena, op);
        previous = op.committed_size;
    }
    var result = sidecar;
    result.ops = kept.items;
    return result;
}

fn readBe64(bytes: []const u8, offset: u64) u64 {
    return std.mem.readInt(u64, bytes[@intCast(offset)..][0..8], .big);
}

fn computeChecksum(file_id: u64, position: u64, root: *const [9]u8, commit_id: u64) u64 {
    var bytes: [33]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], file_id, .big);
    std.mem.writeInt(u64, bytes[8..16], position, .big);
    bytes[16..25].* = root.*;
    std.mem.writeInt(u64, bytes[25..33], commit_id, .big);
    return std.hash.crc.@"CRC-64/XZ".hash(&bytes);
}

fn checkTrailer(path: []const u8, db: []const u8, file_id: u64, end: u64) void {
    if (end < TRAILER_SIZE or end > db.len) fail("{s}: a trailer can't end at {d} in a file of {d} bytes", .{ path, end, db.len });
    const position = end - TRAILER_SIZE;
    const root = db[@intCast(position)..][0..9];
    const commit_id = readBe64(db, position + TRAILER_COMMIT_ID_OFFSET);
    const stored = readBe64(db, position + TRAILER_CHECKSUM_OFFSET);
    const computed = computeChecksum(file_id, position, root, commit_id);
    if (stored != computed) fail("{s}: the trailer at {d} has checksum {x:0>16}, but it should be {x:0>16}", .{ path, position, stored, computed });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const ignore_reads = args.len == 4 and std.mem.eql(u8, args[1], "--ignore-reads");
    if (args.len != 3 and !ignore_reads) {
        std.debug.print("usage: detcheck [--ignore-reads] <a.db> <b.db>\n", .{});
        std.process.exit(2);
    }
    const path_a = args[args.len - 2];
    const path_b = args[args.len - 1];

    var side_a = try readSidecar(io, arena, path_a);
    var side_b = try readSidecar(io, arena, path_b);
    if (side_a.databases.len > 0 or side_b.databases.len > 0) return checkSeveral(io, arena, path_a, path_b, side_a, side_b);

    const a = try Io.Dir.cwd().readFileAlloc(io, path_a, arena, .unlimited);
    const b = try Io.Dir.cwd().readFileAlloc(io, path_b, arena, .unlimited);
    if (ignore_reads) {
        side_a = try withoutReads(arena, side_a);
        side_b = try withoutReads(arena, side_b);
    }

    // 1. the sidecars agree, and describe these files
    if (side_a.file_id != side_b.file_id) fail("file IDs differ", .{});
    if (side_a.initial_size != side_b.initial_size) fail("initial sizes differ", .{});
    if (side_a.file_size != side_b.file_size) fail("file sizes differ: {d} and {d}", .{ side_a.file_size, side_b.file_size });
    if (side_a.ops.len != side_b.ops.len) fail("op counts differ", .{});
    if (a.len != side_a.file_size) fail("{s} is {d} bytes, but its sidecar says {d}", .{ path_a, a.len, side_a.file_size });
    if (b.len != side_b.file_size) fail("{s} is {d} bytes, but its sidecar says {d}", .{ path_b, b.len, side_b.file_size });
    if (a.len < INITIAL_TRAILER_END) fail("{s} is too short to be a database", .{path_a});
    if (readBe64(a, FILE_ID_OFFSET) != side_a.file_id) fail("{s}: the file ID is not the sidecar's", .{path_a});
    if (readBe64(b, FILE_ID_OFFSET) != side_b.file_id) fail("{s}: the file ID is not the sidecar's", .{path_b});
    checkTrailer(path_a, a, side_a.file_id, INITIAL_TRAILER_END);
    checkTrailer(path_b, b, side_b.file_id, INITIAL_TRAILER_END);

    // the commits whose trailers are still in the file. a transaction starts at the
    // committed size, so the trailers past that point are gone by the time it commits.
    const Commit = struct { position: u64, id_a: u64, id_b: u64, op: usize };
    const live = try arena.alloc(Commit, side_a.ops.len);
    var live_len: usize = 0;

    var previous: ?u64 = side_a.initial_size;
    var commits: usize = 0;
    for (side_a.ops, side_b.ops, 0..) |op_a, op_b, i| {
        if (!std.meta.eql(op_a.committed_size, op_b.committed_size)) fail("op {d}: committed sizes differ", .{i});
        if ((op_a.commit_id == null) != (op_b.commit_id == null)) fail("op {d}: only one run committed", .{i});
        defer previous = op_a.committed_size;

        const size = op_a.committed_size orelse {
            if (op_a.commit_id != null) fail("op {d}: it has a commit ID, but no committed size", .{i});
            continue;
        };
        if (op_a.commit_id) |id_a| {
            const before = previous orelse fail("op {d}: it committed, but the database was closed", .{i});
            if (size <= before) fail("op {d}: it committed, but the committed size didn't grow", .{i});
            var kept: usize = 0;
            for (live[0..live_len]) |commit| {
                if (commit.position < before) {
                    live[kept] = commit;
                    kept += 1;
                }
            }
            live_len = kept;
            live[live_len] = .{ .position = size - TRAILER_SIZE, .id_a = id_a, .id_b = op_b.commit_id.?, .op = i };
            live_len += 1;
            commits += 1;
        } else if (previous) |before| {
            // reopening can move the committed size, but nothing else can without committing
            if (size != before) fail("op {d}: the committed size changed, but it didn't commit", .{i});
        }
    }
    // the trailers of an unfinished transaction can still be there, or be truncated
    var kept_at_end: usize = 0;
    for (live[0..live_len]) |commit| {
        if (commit.position + TRAILER_SIZE <= a.len) {
            live[kept_at_end] = commit;
            kept_at_end += 1;
        }
    }
    live_len = kept_at_end;

    // the root header agrees with the last op, unless that op left the database closed
    if (previous) |size| {
        if (readBe64(a, ROOT_HEADER_FILE_SIZE_OFFSET) != size) fail("{s}: the root header's size is not the last committed size", .{path_a});
        if (readBe64(b, ROOT_HEADER_FILE_SIZE_OFFSET) != size) fail("{s}: the root header's size is not the last committed size", .{path_b});
        if (a.len < size) fail("{s}: the committed size is past the end of the file", .{path_a});
    }

    // what's allowed to differ
    const may_differ = try arena.alloc(bool, a.len);
    @memset(may_differ, false);
    const patched = try arena.dupe(u8, a);

    for (live[0..live_len]) |commit| {
        // 2. and 3.
        if (readBe64(a, commit.position + TRAILER_COMMIT_ID_OFFSET) != commit.id_a) fail("op {d}: {s} doesn't have the sidecar's commit ID", .{ commit.op, path_a });
        if (readBe64(b, commit.position + TRAILER_COMMIT_ID_OFFSET) != commit.id_b) fail("op {d}: {s} doesn't have the sidecar's commit ID", .{ commit.op, path_b });
        checkTrailer(path_a, a, side_a.file_id, commit.position + TRAILER_SIZE);
        checkTrailer(path_b, b, side_b.file_id, commit.position + TRAILER_SIZE);

        @memset(may_differ[@intCast(commit.position + TRAILER_COMMIT_ID_OFFSET)..@intCast(commit.position + TRAILER_SIZE)], true);

        // what the sidecar alone should turn this trailer into
        const offset: usize = @intCast(commit.position);
        std.mem.writeInt(u64, patched[offset + TRAILER_COMMIT_ID_OFFSET..][0..8], commit.id_b, .big);
        std.mem.writeInt(u64, patched[offset + TRAILER_CHECKSUM_OFFSET..][0..8], computeChecksum(side_a.file_id, commit.position, patched[offset..][0..9], commit.id_b), .big);
    }

    // 4.
    var differing: u64 = 0;
    for (a, b, may_differ, 0..) |byte_a, byte_b, allowed, offset| {
        if (byte_a == byte_b) continue;
        if (!allowed) fail("byte {d} differs ({x:0>2} and {x:0>2}), and it isn't part of a trailer's commit ID or checksum", .{ offset, byte_a, byte_b });
        differing += 1;
    }

    // 5.
    if (!std.mem.eql(u8, patched, b)) {
        const offset = std.mem.findDiff(u8, patched, b).?;
        fail("a with b's commit IDs differs from b at byte {d}", .{offset});
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout.interface.print("ok: {d} bytes, {d} commits, {d} of the {d} commit ID and checksum bytes differ, 0 other bytes differ, a + b's commit IDs == b\n", .{
        a.len,
        commits,
        differing,
        live_len * 16,
    });
    try stdout.interface.flush();
}
