//! reader --kinds
//! reader <kind> <file>
//! reader --version
//!
//! The original's own reader for two-processes.sh, doing what SCRIPT-FORMAT.md section 15 says a reader does, so
//! that the test runs with the original on both sides when no port's reader is given, which holds the test itself.
//! It opens the file once, read-only and with no lock, with the storage kind named, and prints `open`. Then, for each
//! line on its standard input, it takes one cursor to the root's last moment, reads n, the blob and the items' count
//! from that cursor only, so that one answer can't mix two commits, and prints `state <n> <sha256 of the blob>
//! <count>`, or `error <name>`. At the end of its input it exits with 0.
//!
//! `reader --version` names the commits it was built from, as `run --version` does, which isn't part of what a reader
//! does: a port's needn't have it.

const std = @import("std");
const xitdb = @import("xitdb");
const Io = std.Io;
// which commits this was built from, for --version: build.zig asks git
const build_options = @import("build_options");

/// a moment's keys are the SHA-1 of these names, as in every script
fn key(comptime name: []const u8) u160 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(name, &digest, .{});
    return std.mem.readInt(u160, &digest, .big);
}

const State = struct { n: u64, blob: [64]u8, count: u64 };

fn read(comptime kind: xitdb.DatabaseKind, db: *xitdb.Database(kind, u160), gpa: std.mem.Allocator) !State {
    // the one cursor: what's read from here is committed, so no commit after it can change it
    const moment = (try db.rootCursor().readPath(void, &.{.{ .array_list_get = -1 }})) orelse return error.NoMoment;
    const n = (try moment.readPath(void, &.{.{ .hash_map_get = .{ .value = key("n") } }})) orelse return error.NoN;
    const blob_cursor = (try moment.readPath(void, &.{.{ .hash_map_get = .{ .value = key("blob") } }})) orelse return error.NoBlob;
    const items = (try moment.readPath(void, &.{.{ .hash_map_get = .{ .value = key("items") } }})) orelse return error.NoItems;
    const blob = try blob_cursor.readBytesAlloc(gpa, null);
    defer gpa.free(blob);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});
    return .{ .n = try n.readUint(), .blob = std.fmt.bytesToHex(digest, .lower), .count = try items.count() };
}

fn serve(comptime kind: xitdb.DatabaseKind, io: Io, gpa: std.mem.Allocator, path: []const u8, out: *Io.Writer) !void {
    const DB = xitdb.Database(kind, u160);
    const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch |err| {
        try out.print("error {s}\n", .{@errorName(err)});
        try out.flush();
        std.process.exit(1);
    };
    defer file.close(io);
    var buffer = Io.Writer.Allocating.init(gpa);
    defer buffer.deinit();
    const opts: xitdb.InitOpts(kind) = switch (kind) {
        .file => .{ .file = file, .fsync = false },
        .buffered_file => .{ .file = file, .buffer = &buffer, .fsync = false },
        .memory => unreachable,
    };
    var db = DB.init(io, opts) catch |err| {
        try out.print("error {s}\n", .{@errorName(err)});
        try out.flush();
        std.process.exit(1);
    };
    try out.writeAll("open\n");
    try out.flush();

    var in_buffer: [256]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(io, &in_buffer);
    while (true) {
        _ = in.interface.takeSentinel('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (read(kind, &db, gpa)) |state| {
            try out.print("state {d} {s} {d}\n", .{ state.n, &state.blob, state.count });
        } else |err| {
            try out.print("error {s}\n", .{@errorName(err)});
        }
        try out.flush();
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buffer: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &stdout.interface;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--kinds")) {
        try out.writeAll("file\nbuffered_file\n");
        try out.flush();
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try out.print("reader: xitdb {s}, conformance {s}\n", .{ build_options.xitdb_commit, build_options.conformance_commit });
        try out.flush();
        return;
    }
    if (args.len != 3) {
        std.debug.print("usage: reader --kinds\n       reader <kind> <file>\n       reader --version\n", .{});
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[1], "file")) return serve(.file, io, init.gpa, args[2], out);
    if (std.mem.eql(u8, args[1], "buffered_file")) return serve(.buffered_file, io, init.gpa, args[2], out);
    std.debug.print("reader: no storage kind called {s}\n", .{args[1]});
    std.process.exit(2);
}
