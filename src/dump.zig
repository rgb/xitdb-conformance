//! dump <file>
//!
//! Prints what's in a database, every moment of it, in a text form that doesn't depend
//! on where anything is in the file. Offsets, sizes and commit IDs don't appear, and
//! collections print in the order of their hashes, keys or indexes. So two files with
//! the same content give the same text, however differently they got there. It's for
//! people debugging a mismatch, and for comparing files where the bytes can't match.
//!
//! The file is opened read-only, and nothing is written to it. Anything that can't be
//! read prints as `error <name>`, and then the exit status is 1.

const std = @import("std");
const xitdb = @import("xitdb");

const Io = std.Io;
// which commits this was built from, for --version: build.zig asks git
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;

const HEADER_SIZE = 20;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("dump: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn Dump(comptime HashInt: type) type {
    return struct {
        const Self = @This();
        const DB = xitdb.Database(.file, HashInt);
        const RO = DB.Cursor(.read_only);
        const Slot = xitdb.Slot;
        const HASH_SIZE = @bitSizeOf(HashInt) / 8;

        w: *Io.Writer,
        arena: Allocator,
        errors: usize = 0,
        // the collections around the one being printed. overwriting committed bytes can
        // make one contain itself.
        ancestors: std.ArrayList(Slot) = .empty,

        fn indent(self: *Self, level: usize) !void {
            for (0..level) |_| try self.w.writeAll("  ");
        }

        fn line(self: *Self, level: usize, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
            try self.indent(level);
            try self.w.print("{s}: " ++ fmt ++ "\n", .{label} ++ args);
        }

        fn printError(self: *Self, level: usize, label: []const u8, err: anyerror) !void {
            self.errors += 1;
            try self.line(level, label, "error {s}", .{@errorName(err)});
        }

        fn writeBytes(self: *Self, bytes: []const u8) !void {
            for (bytes) |b| {
                if (b < 0x20 or b > 0x7e or b == '"' or b == '\\') {
                    try self.w.writeAll("hex ");
                    for (bytes) |h| try self.w.print("{x:0>2}", .{h});
                    return;
                }
            }
            try self.w.print("\"{s}\"", .{bytes});
        }

        fn printBytes(self: *Self, level: usize, label: []const u8, tag_name: []const u8, cursor: RO) !void {
            const bytes = cursor.readBytesObjectAlloc(self.arena, null) catch |err| return self.printError(level, label, err);
            try self.indent(level);
            try self.w.print("{s}: {s} ", .{ label, tag_name });
            try self.writeBytes(bytes.value);
            if (bytes.format_tag) |format_tag| {
                try self.w.writeAll(" format tag ");
                try self.writeBytes(&format_tag);
            }
            try self.w.writeAll("\n");
        }

        fn hashText(self: *Self, hash: HashInt) []const u8 {
            var bytes: [HASH_SIZE]u8 = undefined;
            std.mem.writeInt(HashInt, &bytes, hash, .big);
            const out = self.arena.alloc(u8, HASH_SIZE * 2) catch fail("out of memory", .{});
            const digits = "0123456789abcdef";
            for (bytes, 0..) |b, i| {
                out[i * 2] = digits[b >> 4];
                out[i * 2 + 1] = digits[b & 15];
            }
            return out;
        }

        fn printEntry(self: *Self, level: usize, label: []const u8, entry: RO) anyerror!void {
            const pair = entry.readKeyValuePair() catch |err| return self.printError(level, label, err);
            try self.indent(level);
            try self.w.print("{s}:\n", .{label});
            const key_slot = try pair.key_cursor.slot();
            if (!key_slot.empty()) try self.printValue(level + 1, "key", pair.key_cursor);
            const value_slot = try pair.value_cursor.slot();
            if (!value_slot.empty()) try self.printValue(level + 1, "value", pair.value_cursor);
        }

        fn printHashEntries(self: *Self, level: usize, cursor: RO) anyerror!void {
            var iter = cursor.iterator() catch |err| return self.printError(level, "entries", err);
            while (true) {
                const next = iter.next() catch |err| return self.printError(level, "next entry", err);
                const entry = next orelse return;
                const pair = entry.readKeyValuePair() catch |err| {
                    try self.printError(level, "entry", err);
                    continue;
                };
                const label = std.fmt.allocPrint(self.arena, "entry {s}", .{self.hashText(pair.hash)}) catch fail("out of memory", .{});
                try self.printEntry(level, label, entry);
            }
        }

        fn printElements(self: *Self, level: usize, cursor: RO, size: u64, comptime linked: bool) anyerror!void {
            var i: u64 = 0;
            while (i < size) : (i += 1) {
                const label = std.fmt.allocPrint(self.arena, "[{d}]", .{i}) catch fail("out of memory", .{});
                const index: i65 = @intCast(i);
                const found = if (linked)
                    cursor.readPath(void, &.{.{ .linked_array_list_get = index }})
                else
                    cursor.readPath(void, &.{.{ .array_list_get = index }});
                const result = found catch |err| {
                    try self.printError(level, label, err);
                    continue;
                };
                if (result) |element| {
                    try self.printValue(level, label, element);
                } else {
                    try self.line(level, label, "empty", .{});
                }
            }
        }

        fn printSortedEntries(self: *Self, level: usize, cursor: RO, size: u64) anyerror!void {
            var i: u64 = 0;
            while (i < size) : (i += 1) {
                const label = std.fmt.allocPrint(self.arena, "[{d}]", .{i}) catch fail("out of memory", .{});
                const found = cursor.readPath(void, &.{.{ .sorted_map_get_index = @intCast(i) }}) catch |err| {
                    try self.printError(level, label, err);
                    continue;
                };
                if (found) |entry| {
                    try self.printEntry(level, label, entry);
                } else {
                    try self.line(level, label, "empty", .{});
                }
            }
        }

        fn printValue(self: *Self, level: usize, label: []const u8, cursor: RO) anyerror!void {
            const slot = cursor.slot() catch |err| return self.printError(level, label, err);
            switch (slot.tag) {
                .none => try self.line(level, label, "{s}", .{if (slot.full) "null" else "empty"}),
                .uint => {
                    const value = cursor.readUint() catch |err| return self.printError(level, label, err);
                    try self.line(level, label, "uint {d}", .{value});
                },
                .int => {
                    const value = cursor.readInt() catch |err| return self.printError(level, label, err);
                    try self.line(level, label, "int {d}", .{value});
                },
                .float => {
                    const value = cursor.readFloat() catch |err| return self.printError(level, label, err);
                    const bits: u64 = @bitCast(value);
                    try self.line(level, label, "float {x:0>16}", .{bits});
                },
                .bytes, .short_bytes => try self.printBytes(level, label, @tagName(slot.tag), cursor),
                .array_list, .linked_array_list, .hash_map, .hash_set, .counted_hash_map, .counted_hash_set, .sorted_map, .sorted_set => {
                    for (self.ancestors.items) |ancestor| {
                        if (ancestor.eql(slot)) {
                            try self.line(level, label, "{s} containing itself", .{@tagName(slot.tag)});
                            return;
                        }
                    }
                    self.ancestors.append(self.arena, slot) catch fail("out of memory", .{});
                    defer _ = self.ancestors.pop();

                    switch (slot.tag) {
                        .hash_map, .hash_set => {
                            try self.line(level, label, "{s}", .{@tagName(slot.tag)});
                            try self.printHashEntries(level + 1, cursor);
                        },
                        else => {
                            const size = cursor.count() catch |err| return self.printError(level, label, err);
                            try self.line(level, label, "{s} of {d}", .{ @tagName(slot.tag), size });
                            switch (slot.tag) {
                                .array_list => try self.printElements(level + 1, cursor, size, false),
                                .linked_array_list => try self.printElements(level + 1, cursor, size, true),
                                .sorted_map, .sorted_set => try self.printSortedEntries(level + 1, cursor, size),
                                else => try self.printHashEntries(level + 1, cursor),
                            }
                        },
                    }
                },
                // these only show up if they were written where a value goes, which isn't defined
                .index, .kv_pair, .sorted_kv_pair => try self.line(level, label, "{s}", .{@tagName(slot.tag)}),
            }
        }

        fn printRoot(self: *Self, root: RO) !void {
            const slot = root.slot() catch |err| return self.printError(0, "root", err);
            if (slot.tag != .array_list) return self.printValue(0, "root", root);
            const size = root.count() catch |err| return self.printError(0, "moments", err);
            try self.line(0, "moments", "{d}", .{size});
            self.ancestors.append(self.arena, slot) catch fail("out of memory", .{});
            var i: u64 = 0;
            while (i < size) : (i += 1) {
                const label = std.fmt.allocPrint(self.arena, "moment {d}", .{i}) catch fail("out of memory", .{});
                const found = root.readPath(void, &.{.{ .array_list_get = @as(i65, @intCast(i)) }}) catch |err| {
                    try self.printError(0, label, err);
                    continue;
                };
                if (found) |moment| {
                    try self.printValue(0, label, moment);
                } else {
                    try self.line(0, label, "empty", .{});
                }
            }
        }

        fn run(io: Io, arena: Allocator, file: Io.File, w: *Io.Writer) !usize {
            var db = DB.init(io, .{ .file = file, .fsync = false }) catch |err| fail("the file can't be opened: {s}", .{@errorName(err)});
            var self: Self = .{ .w = w, .arena = arena };
            try self.printRoot(db.rootCursor().readOnly());
            return self.errors;
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: dump <file>\n       dump --version\n", .{});
        std.process.exit(2);
    }
    if (std.mem.eql(u8, args[1], "--version")) {
        var buffer: [512]u8 = undefined;
        var stdout = Io.File.stdout().writerStreaming(io, &buffer);
        try stdout.interface.print("dump: xitdb {s}, conformance {s}\n", .{ build_options.xitdb_commit, build_options.conformance_commit });
        try stdout.interface.flush();
        return;
    }

    const file = Io.Dir.cwd().openFile(io, args[1], .{ .mode = .read_only }) catch |err| fail("{s}: {s}", .{ args[1], @errorName(err) });
    defer file.close(io);

    var header: [HEADER_SIZE]u8 = undefined;
    var reader = file.reader(io, &.{});
    reader.interface.readSliceAll(&header) catch fail("{s} is too short to be a database", .{args[1]});
    if (!std.mem.eql(u8, header[0..3], "xit")) fail("{s} isn't a xitdb file", .{args[1]});

    const version = std.mem.readInt(u16, header[4..6], .big);
    const hash_size = std.mem.readInt(u16, header[6..8], .big);
    const hash_id = header[8..12];
    const file_id = std.mem.readInt(u64, header[12..20], .big);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout.interface;

    try w.print("version: {d}\nhash size: {d}\nhash id: ", .{ version, hash_size });
    if (std.mem.allEqual(u8, hash_id, 0)) {
        try w.writeAll("none");
    } else {
        var printable = true;
        for (hash_id) |b| {
            if (b < 0x21 or b > 0x7e) printable = false;
        }
        if (printable) {
            try w.print("{s}", .{hash_id});
        } else {
            for (hash_id) |b| try w.print("{x:0>2}", .{b});
        }
    }
    try w.print("\nfile id: {x:0>16}\n", .{file_id});

    const errors = switch (hash_size) {
        8 => try Dump(u64).run(io, arena, file, w),
        20 => try Dump(u160).run(io, arena, file, w),
        32 => try Dump(u256).run(io, arena, file, w),
        64 => try Dump(u512).run(io, arena, file, w),
        else => fail("a hash size of {d} isn't one this tool is built for", .{hash_size}),
    };
    try w.flush();
    if (errors > 0) {
        std.debug.print("dump: {d} things couldn't be read\n", .{errors});
        std.process.exit(1);
    }
}
