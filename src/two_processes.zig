//! two-processes <reader> <kind> <folder>
//!
//! The writer for two-processes.sh, on the original: it commits states to a file while the reader, another process
//! given by its path, opened once on that file with the storage kind named and no lock, is asked what it sees
//! (SCRIPT-FORMAT.md section 15). It holds the reader to the rule:
//!
//! - every answer is a state the writer committed, it never goes back to an earlier one, and none is an error;
//! - once the writer has finished, the next answer is the last state;
//! - after the writer compacts the file into a new one and renames that over the old one's name, a reader that kept
//!   the old file open goes on seeing the old file's last state, whole, whatever is committed to the new one, and a
//!   reader opened after the rename sees the new file's states, and then its last.
//!
//! Three runs: "a commit, then a question", where the writer commits and then asks; "questions during a commit",
//! where it asks several times and commits while the reader answers; and "after the rename". It exits with 0 if the
//! rule held, and says where it didn't otherwise.
//!
//! While it runs, the folder holds `run`, the words of the run it's in, and `readers`, the process ID of each reader
//! it has started, each the leader of a process group of its own. So when two-processes.sh's alarm ends it, the
//! script can say which run a reader stopped answering in, and end whatever is left of the readers.

const std = @import("std");
const xitdb = @import("xitdb");
const Io = std.Io;

const DB = xitdb.Database(.file, u160);
const RW = DB.Cursor(.read_write);
const Map = DB.HashMap(.read_write);
const List = DB.ArrayList(.read_write);

const WITH_A_PAUSE = 300;
const WITHOUT_A_PAUSE = 300;
const ASKED_AT_ONCE = 4;
const AFTER_THE_RENAME = 50;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("two-processes: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// a moment's keys are the SHA-1 of these names, as in every script
fn key(comptime name: []const u8) u160 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(name, &digest, .{});
    return std.mem.readInt(u160, &digest, .big);
}

/// state k's blob, whose length and contents depend on k, a few kilobytes, so that a moment spans blocks and an answer
/// that mixed two commits would show
fn blobOf(gpa: std.mem.Allocator, k: u64) ![]u8 {
    const blob = try gpa.alloc(u8, @intCast(2000 + 13 * k));
    for (blob, 0..) |*byte, i| byte.* = @truncate(k *% 7 +% i *% 31);
    return blob;
}

/// moment k: the last moment copied, and in it n, the blob, and one more of the items
const Moment = struct {
    k: u64,
    blob: []const u8,

    pub fn run(self: Moment, cursor: *RW) !void {
        const moment = try Map.init(cursor.*);
        try moment.put(key("n"), .{ .uint = self.k });
        try moment.put(key("blob"), .{ .bytes = self.blob });
        const items = try List.init(try moment.putCursor(key("items")));
        if (self.k > 0) try items.append(.{ .uint = self.k });
    }
};

const Writer = struct {
    io: Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    file: Io.File,
    db: DB,
    history: List,
    /// the line a reader gives for each state, by its n
    lines: std.ArrayList([]const u8) = .empty,

    fn commit(self: *Writer, k: u64) !void {
        const blob = try blobOf(self.gpa, k);
        defer self.gpa.free(blob);
        const previous = if (k == 0) null else try self.history.getSlot(-1);
        try self.history.appendContext(.{ .slot = previous }, Moment{ .k = k, .blob = blob });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});
        try self.lines.append(self.arena, try std.fmt.allocPrint(self.arena, "state {d} {s} {d}", .{ k, &std.fmt.bytesToHex(digest, .lower), k }));
    }

    fn last(self: *Writer) []const u8 {
        return self.lines.items[self.lines.items.len - 1];
    }

    /// the state an answer is, if the writer committed it
    fn stateOf(self: *Writer, line: []const u8) ?u64 {
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, words.next() orelse return null, "state")) return null;
        const n = std.fmt.parseInt(u64, words.next() orelse return null, 10) catch return null;
        if (n >= self.lines.items.len or !std.mem.eql(u8, self.lines.items[@intCast(n)], line)) return null;
        return n;
    }
};

/// what two-processes.sh reads if the alarm ends this: the run, and the readers' process IDs
const Record = struct {
    io: Io,
    arena: std.mem.Allocator,
    folder: []const u8,
    pids: std.ArrayList(u8) = .empty,

    fn write(self: *Record, name: []const u8, data: []const u8) void {
        const path = std.fs.path.join(self.arena, &.{ self.folder, name }) catch fail("out of memory", .{});
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data }) catch |err| fail("{s} couldn't be written: {s}", .{ path, @errorName(err) });
    }

    fn run(self: *Record, words: []const u8) void {
        self.write("run", words);
    }

    fn started(self: *Record, pid: anytype) void {
        self.pids.print(self.arena, "{d}\n", .{pid}) catch fail("out of memory", .{});
        self.write("readers", self.pids.items);
    }
};

const Reader = struct {
    name: []const u8,
    child: std.process.Child,
    in_buffer: [64]u8 = undefined,
    out_buffer: [512]u8 = undefined,
    in: Io.File.Writer = undefined,
    out: Io.File.Reader = undefined,
    /// the state it last answered
    seen: ?u64 = null,
    answers: u64 = 0,

    fn start(io: Io, arena: std.mem.Allocator, record: *Record, name: []const u8, argv: []const []const u8) !*Reader {
        const self = try arena.create(Reader);
        self.* = .{
            .name = name,
            // a process group of its own, so that whatever it starts can be ended with it
            .child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit, .pgid = 0 }) catch |err|
                fail("{s} couldn't be started: {s}", .{ argv[0], @errorName(err) }),
        };
        record.started(self.child.id.?);
        self.in = self.child.stdin.?.writerStreaming(io, &self.in_buffer);
        self.out = self.child.stdout.?.readerStreaming(io, &self.out_buffer);
        const first = self.line();
        if (!std.mem.eql(u8, first, "open")) fail("{s} said \"{s}\" when it opened the file, not \"open\"", .{ name, first });
        return self;
    }

    fn line(self: *Reader) []const u8 {
        return self.out.interface.takeSentinel('\n') catch |err| fail("{s} gave no answer: {s}", .{ self.name, @errorName(err) });
    }

    fn send(self: *Reader, times: usize) void {
        for (0..times) |_| self.in.interface.writeAll("read\n") catch |err| fail("{s} couldn't be asked: {s}", .{ self.name, @errorName(err) });
        self.in.interface.flush() catch |err| fail("{s} couldn't be asked: {s}", .{ self.name, @errorName(err) });
    }

    /// an answer that has to be one of the writer's states, and not before the last it gave
    fn check(self: *Reader, writer: *Writer, what: []const u8) void {
        const answer = self.line();
        self.answers += 1;
        if (std.mem.startsWith(u8, answer, "error")) fail("{s}, {s}: an answer was \"{s}\"", .{ self.name, what, answer });
        const n = writer.stateOf(answer) orelse fail("{s}, {s}: \"{s}\" isn't a state the writer committed", .{ self.name, what, answer });
        if (self.seen) |seen| {
            if (n < seen) fail("{s}, {s}: it went back from state {d} to state {d}", .{ self.name, what, seen, n });
        }
        self.seen = n;
    }

    /// an answer that has to be exactly this state
    fn expect(self: *Reader, want: []const u8, what: []const u8) void {
        const answer = self.line();
        self.answers += 1;
        if (!std.mem.eql(u8, answer, want)) fail("{s}, {s}: it said \"{s}\" where it should have said \"{s}\"", .{ self.name, what, answer, want });
    }

    fn finish(self: *Reader, io: Io) void {
        self.child.stdin.?.close(io);
        self.child.stdin = null;
        const term = self.child.wait(io) catch |err| fail("{s} couldn't be waited for: {s}", .{ self.name, @errorName(err) });
        if (!term.success()) fail("{s} didn't exit with 0 at the end of its input", .{self.name});
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) {
        std.debug.print("usage: two-processes <reader> <kind> <folder>\n", .{});
        std.process.exit(2);
    }
    const reader_path, const kind, const folder = .{ args[1], args[2], args[3] };
    try Io.Dir.cwd().createDirPath(io, folder);
    const path = try std.fs.path.join(arena, &.{ folder, "db.db" });
    const new_path = try std.fs.path.join(arena, &.{ folder, "compacted.db" });

    var record = Record{ .io = io, .arena = arena, .folder = folder };
    record.run("opening the file");
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    var writer = Writer{ .io = io, .gpa = gpa, .arena = arena, .file = file, .db = undefined, .history = undefined };
    writer.db = try DB.init(io, .{ .file = file, .hash_id = xitdb.HashId.fromBytes("sha1"), .file_id = 0x2b0c0e55e5000001 });
    writer.history = try List.init(writer.db.rootCursor());
    try writer.commit(0);

    // with a pause: commit, then ask
    const first = try Reader.start(io, arena, &record, "the reader", &.{ reader_path, kind, path });
    record.run("a commit, then a question");
    first.send(1);
    first.check(&writer, "before the first commit");
    var k: u64 = 1;
    while (k <= WITH_A_PAUSE) : (k += 1) {
        try writer.commit(k);
        first.send(1);
        first.check(&writer, "with a pause");
    }
    first.send(1);
    first.expect(writer.last(), "once the writer had finished with a pause");

    // without one: ask, and commit while the reader answers
    record.run("questions during a commit");
    while (k <= WITH_A_PAUSE + WITHOUT_A_PAUSE) : (k += 1) {
        first.send(ASKED_AT_ONCE);
        try writer.commit(k);
        for (0..ASKED_AT_ONCE) |_| first.check(&writer, "without a pause");
    }
    first.send(1);
    first.expect(writer.last(), "once the writer had finished without a pause");

    // the rename: compacted into a new file, which takes the old one's name
    record.run("after the rename");
    const old_last = writer.last();
    const new_file = try Io.Dir.cwd().createFile(io, new_path, .{ .read = true, .truncate = true });
    var offsets = std.AutoHashMap(u64, u64).init(gpa);
    defer offsets.deinit();
    const compacted = try writer.db.compact(.file, .{ .file = new_file, .hash_id = xitdb.HashId.fromBytes("sha1"), .file_id = 0x2b0c0e55e5000002 }, &offsets);
    try Io.Dir.cwd().rename(new_path, Io.Dir.cwd(), path, io);
    writer.file.close(io);
    writer.file = new_file;
    writer.db = compacted;
    writer.history = try List.init(writer.db.rootCursor());

    first.send(1);
    first.expect(old_last, "the old file, just after the rename");
    const second = try Reader.start(io, arena, &record, "the reader opened after the rename", &.{ reader_path, kind, path });
    second.send(1);
    second.check(&writer, "after the rename");
    while (k <= WITH_A_PAUSE + WITHOUT_A_PAUSE + AFTER_THE_RENAME) : (k += 1) {
        try writer.commit(k);
        first.send(1);
        first.expect(old_last, "the old file, after a commit to the new one");
        second.send(1);
        second.check(&writer, "after the rename");
    }
    second.send(1);
    second.expect(writer.last(), "once the writer had finished after the rename");
    first.send(1);
    first.expect(old_last, "the old file, once the writer had finished");

    first.finish(io);
    second.finish(io);
    writer.file.close(io);
    std.debug.print("{s} on {s}: {d} commits with a pause, {d} without, and {d} to a compacted file renamed over the old one; {d} answers, each a committed state, none going back and none an error, and the last state once the writer had finished; the reader that kept the old file saw its last state every time\n", .{
        reader_path, kind, WITH_A_PAUSE, WITHOUT_A_PAUSE, AFTER_THE_RENAME, first.answers + second.answers,
    });
}
