//! longscripts <folder>
//!
//! Writes the scripts in tests/valid that are too long to write by hand. They are
//! written to be read like the others, and all the numbers in them, expectations
//! included, are arithmetic here and don't come from the engine. So unlike gen's
//! scripts, what they expect is a claim that `run` can find wrong. They're committed,
//! and the gate checks that this still writes exactly them.
//!
//! The `deep-*` scripts are about the difference between rewriting in place and
//! copying. A transaction changes in place what it made itself, and copies what's
//! older than its start or a freeze. If a script only touches a few keys per
//! transaction, or has one transaction per write, then an engine that gets this wrong
//! in either direction writes the same file. These have transactions of hundreds of
//! writes that go back through what they made, so it can't.
//!
//! The `iterator-tiers*` scripts walk collections that are several levels deep, from
//! starting points on either side of where a block or a node ends.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("longscripts: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const S = struct {
    w: *Io.Writer,
    depth: usize = 0,
    has_ops: [4]bool = @splat(false),

    fn separator(self: *S) !void {
        if (self.has_ops[self.depth]) try self.w.writeAll(",");
        self.has_ops[self.depth] = true;
        try self.w.writeAll("\n");
        for (0..(self.depth + 2) * 2) |_| try self.w.writeAll(" ");
    }

    fn op(self: *S, comptime fmt: []const u8, args: anytype) !void {
        try self.separator();
        try self.w.print(fmt, args);
    }

    /// an op whose text ends with the start of a list of ops
    fn open(self: *S, comptime fmt: []const u8, args: anytype) !void {
        try self.op(fmt, args);
        self.depth += 1;
        self.has_ops[self.depth] = false;
    }

    fn close(self: *S, text: []const u8) !void {
        self.depth -= 1;
        try self.w.writeAll("\n");
        for (0..(self.depth + 2) * 2) |_| try self.w.writeAll(" ");
        try self.w.writeAll(text);
    }

    // a new moment, starting from the last one, as the README's examples do

    fn beginMoment(self: *S) !void {
        try self.op("{{\"op\":\"read_path_slot\",\"on\":\"root\",\"path\":[{{\"array_list_get\":-1}}],\"as\":\"last\"}}", .{});
        try self.open("{{\"op\":\"write_path\",\"on\":\"root\",\"path\":[\"array_list_init\",\"array_list_append\",{{\"write\":{{\"slot\":{{\"var\":\"last\"}}}}}},{{\"hash_map_init\":{{}}}},{{\"ctx\":{{\"as\":\"m\",\"ops\":[", .{});
    }

    fn endMoment(self: *S) !void {
        try self.close("]}}]}");
    }

    // everything from before this has to be copied now, and the map as well
    fn freeze(self: *S) !void {
        try self.op("{{\"op\":\"db_freeze\",\"note\":\"from here on, what this transaction has made so far gets copied too\"}}", .{});
        try self.op("{{\"op\":\"write_path\",\"on\":\"m\",\"path\":[{{\"hash_map_init\":{{}}}}],\"as\":\"m\"}}", .{});
    }

    fn write(self: *S, comptime fmt: []const u8, args: anytype) !void {
        try self.op("{{\"op\":\"write_path\",\"on\":\"m\",\"path\":[" ++ fmt ++ "]}}", args);
    }

    fn readMoment(self: *S, index: i64) !void {
        try self.op("{{\"op\":\"read_path\",\"on\":\"root\",\"path\":[{{\"array_list_get\":{d}}}],\"as\":\"moment\"}}", .{index});
    }
};

/// a clone of what's under `key`, made with a freeze on its cursor, so that writes through
/// it copy what's older than that point, even if this transaction made it. it's for the end
/// of a transaction: writing to the original after this would be two headers for one tree.
fn cloneFrozen(s: *S, comptime key: []const u8, comptime clone_key: []const u8) !void {
    try s.op("{{\"op\":\"read_path_slot\",\"on\":\"m\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"" ++ key ++ "\"}}}}}}],\"as\":\"original\"}}", .{});
    try s.op("{{\"op\":\"write_path\",\"on\":\"m\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"" ++ clone_key ++ "\"}}}}}}],\"as\":\"clone\"}}", .{});
    try s.op("{{\"op\":\"write\",\"on\":\"clone\",\"data\":{{\"slot\":{{\"var\":\"original\"}}}}}}", .{});
    try s.op("{{\"op\":\"freeze\",\"on\":\"clone\"}}", .{});
}

fn begin(w: *Io.Writer, description: []const u8) !S {
    try w.print("{{\n  \"format\": \"xitdb-script/1\",\n  \"description\": \"{s} Written by src/longscripts.zig.\",\n  \"hash_size\": 20,\n  \"hash_id\": \"sha1\",\n  \"file_id\": \"0011223344556677\",\n  \"ops\": [", .{description});
    return .{ .w = w };
}

fn end(w: *Io.Writer) !void {
    try w.writeAll("\n  ]\n}\n");
}

// the deep transactions, with array lists and hash maps

// these go in format strings, which is why the braces are doubled
const GET_LIST = "{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list\"}}}}}},\"array_list_init\"";

fn putKey(s: *S, i: u64, value: u64) !void {
    if (value % 10 == 3) {
        try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"key-{d}\"}}}}}},{{\"write\":{{\"bytes\":\"the value {d}, which is too long for a slot\"}}}}", .{ i, value });
    } else {
        try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"key-{d}\"}}}}}},{{\"write\":{{\"uint\":{d}}}}}", .{ i, value });
    }
}

fn removeKey(s: *S, i: u64) !void {
    try s.write("{{\"hash_map_remove\":{{\"sha1\":\"key-{d}\"}}}}", .{i});
}

fn listAppend(s: *S, value: u64) !void {
    try s.write(GET_LIST ++ ",\"array_list_append\",{{\"write\":{{\"uint\":{d}}}}}", .{value});
}

fn listSet(s: *S, index: u64, value: u64) !void {
    try s.write(GET_LIST ++ ",{{\"array_list_get\":{d}}},{{\"write\":{{\"uint\":{d}}}}}", .{ index, value });
}

fn listSlice(s: *S, size: u64) !void {
    try s.write(GET_LIST ++ ",{{\"array_list_slice\":{{\"size\":{d}}}}}", .{size});
}

/// `hash` nibbles from the low end are 0 and the next is 1, so the keys
/// share ever more of the path into the trie, which goes as deep as they do
fn deepHash(level: u64) [40]u8 {
    var hex: [40]u8 = @splat('0');
    hex[39 - @as(usize, @intCast(level))] = '1';
    return hex;
}

fn putDeep(s: *S, level: u64, value: u64) !void {
    const hex = deepHash(level);
    try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"deep\"}}}}}},{{\"hash_map_init\":{{}}}},{{\"hash_map_get\":{{\"value\":{{\"hex\":\"{s}\"}}}}}},{{\"write\":{{\"uint\":{d}}}}}", .{ &hex, value });
}

fn putCounted(s: *S, i: u64, value: u64) !void {
    try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"counted\"}}}}}},{{\"hash_map_init\":{{\"counted\":true}}}},{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"c{d}\"}}}}}},{{\"write\":{{\"uint\":{d}}}}}", .{ i, value });
}

fn removeCounted(s: *S, i: u64) !void {
    try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"counted\"}}}}}},{{\"hash_map_init\":{{\"counted\":true}}}},{{\"hash_map_remove\":{{\"sha1\":\"c{d}\"}}}}", .{i});
}

fn putSet(s: *S, comptime name: []const u8, comptime init: []const u8, i: u64) !void {
    try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"" ++ name ++ "\"}}}}}},{{\"hash_map_init\":" ++ init ++ "}},{{\"hash_map_get\":{{\"key\":{{\"sha1\":\"s{d}\"}}}}}},{{\"write\":{{\"bytes\":\"s{d}\"}}}}", .{ i, i });
}

fn removeSet(s: *S, comptime name: []const u8, comptime init: []const u8, i: u64) !void {
    try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"" ++ name ++ "\"}}}}}},{{\"hash_map_init\":" ++ init ++ "}},{{\"hash_map_remove\":{{\"sha1\":\"s{d}\"}}}}", .{i});
}

const SET = "{{\"set\":true}}";
const COUNTED_SET = "{{\"counted\":true,\"set\":true}}";

fn deepTries(w: *Io.Writer) !void {
    var s = try begin(w, "Hash maps of every kind and an array list, in transactions of hundreds of writes that go back through the blocks they made, which are rewritten in place, and through older ones, which are copied. It has a freeze halfway through one, after which what that transaction made gets copied too.");

    try s.beginMoment();
    for (0..300) |i| try putKey(&s, i, i);
    for (0..300) |i| try listAppend(&s, i);
    for (0..14) |level| try putDeep(&s, level, level);
    for (0..100) |i| try putCounted(&s, i, i);
    for (0..100) |i| try putSet(&s, "set", SET, i);
    for (0..100) |i| try putSet(&s, "counted_set", COUNTED_SET, i);
    // back through what this transaction made
    for (0..50) |i| try putKey(&s, i * 3, 1000 + i);
    for (0..30) |i| try removeKey(&s, 100 + i);
    for (0..10) |i| try putKey(&s, 100 + i, 2000 + i);
    for (0..50) |i| try listSet(&s, (i * 7) % 300, 3000 + i);
    try listSlice(&s, 200);
    for (0..20) |i| try listAppend(&s, 4000 + i);
    for (0..14) |level| try putDeep(&s, level, 100 + level);
    for (0..20) |i| try removeCounted(&s, i);
    for (0..20) |i| try removeSet(&s, "counted_set", COUNTED_SET, i);
    try s.endMoment();

    try s.beginMoment();
    // what the last transaction made is old now, and only the first touch copies it
    for (0..150) |i| try putKey(&s, i * 2, 5000 + i);
    for (300..450) |i| try putKey(&s, i, i);
    for (0..200) |i| try listAppend(&s, 6000 + i);
    for (0..50) |i| try listSet(&s, (i * 11) % 420, 7000 + i);
    for (0..14) |level| try putDeep(&s, level, 200 + level);
    for (0..40) |i| try putCounted(&s, 100 + i, i);
    for (0..40) |i| try removeCounted(&s, 20 + i);
    for (0..40) |i| try putSet(&s, "set", SET, 100 + i);
    for (0..40) |i| try removeSet(&s, "set", SET, i);
    // and this goes through what those copies are now
    for (0..50) |i| try putKey(&s, i * 2, 8000 + i);
    try s.endMoment();

    try s.beginMoment();
    for (0..100) |i| try putKey(&s, i * 4, 9000 + i);
    for (0..50) |i| try listAppend(&s, 10000 + i);
    try s.freeze();
    for (0..100) |i| try putKey(&s, i * 4, 11000 + i);
    for (0..50) |i| try listSet(&s, 420 + i, 12000 + i);
    for (0..14) |level| try putDeep(&s, level, 300 + level);
    try listSlice(&s, 100);
    for (0..30) |i| try listAppend(&s, 13000 + i);
    // through frozen cursors, which copy what this transaction made before them
    try cloneFrozen(&s, "list", "list_clone");
    for (0..100) |i| try s.op("{{\"op\":\"write_path\",\"on\":\"clone\",\"path\":[\"array_list_init\",\"array_list_append\",{{\"write\":{{\"uint\":{d}}}}}]}}", .{14000 + i});
    for (0..50) |i| try s.op("{{\"op\":\"write_path\",\"on\":\"clone\",\"path\":[\"array_list_init\",{{\"array_list_get\":{d}}},{{\"write\":{{\"uint\":{d}}}}}]}}", .{ i * 2, 15000 + i });
    try cloneFrozen(&s, "counted", "counted_clone");
    for (0..60) |i| try s.op("{{\"op\":\"write_path\",\"on\":\"clone\",\"path\":[{{\"hash_map_init\":{{\"counted\":true}}}},{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"clone-{d}\"}}}}}},{{\"write\":{{\"uint\":{d}}}}}]}}", .{ i, i });
    try s.endMoment();

    // what came of it. the sizes are 300 - 100 + 20, then 200 more, then 50 more, cut to 100, then 30 more
    for ([_]u64{ 220, 420, 130 }, 0..) |size, moment| {
        try s.readMoment(@intCast(moment));
        try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list\"}}}}}}],\"as\":\"list\"}}", .{});
        try s.op("{{\"op\":\"count\",\"on\":\"list\",\"expect\":{d}}}", .{size});
    }
    try s.readMoment(0);
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"key-1\"}}}}}}],\"as\":\"v\"}}", .{});
    try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":1}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"key-120\"}}}}}}],\"expect_null\":true,\"note\":\"removed, and not one of the ten put back\"}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"counted\"}}}}}}],\"as\":\"counted\"}}", .{});
    try s.op("{{\"op\":\"count\",\"on\":\"counted\",\"expect\":80}}", .{});
    try s.readMoment(1);
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"key-2\"}}}}}}],\"as\":\"v\"}}", .{});
    try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":8001,\"note\":\"written twice in this moment\"}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"counted\"}}}}}}],\"as\":\"counted\"}}", .{});
    try s.op("{{\"op\":\"count\",\"on\":\"counted\",\"expect\":80}}", .{});
    try s.readMoment(2);
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"key-4\"}}}}}}],\"as\":\"v\"}}", .{});
    try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":11001,\"note\":\"written on either side of the freeze\"}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list\"}}}}}},{{\"array_list_get\":-1}}],\"as\":\"v\"}}", .{});
    try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":13029}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list_clone\"}}}}}}],\"as\":\"clone\"}}", .{});
    try s.op("{{\"op\":\"count\",\"on\":\"clone\",\"expect\":230}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list\"}}}}}},{{\"array_list_get\":0}}],\"as\":\"v\",\"note\":\"the clone's writes didn't reach the original\"}}", .{});
    try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":7000}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list_clone\"}}}}}},{{\"array_list_get\":0}}],\"as\":\"v\"}}", .{});
    try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":15000}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"counted_clone\"}}}}}}],\"as\":\"clone\"}}", .{});
    try s.op("{{\"op\":\"count\",\"on\":\"clone\",\"expect\":140}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"counted\"}}}}}}],\"as\":\"counted\"}}", .{});
    try s.op("{{\"op\":\"count\",\"on\":\"counted\",\"expect\":80}}", .{});
    try end(w);
}

// the deep transactions, with linked array lists

const GET_LINKED = "{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list\"}}}}}},\"linked_array_list_init\"";

/// follows what a list's size will be, so that every index in the script is in range
const Linked = struct {
    s: *S,
    size: u64,

    fn append(self: *Linked, value: u64) !void {
        try self.s.write(GET_LINKED ++ ",\"linked_array_list_append\",{{\"write\":{{\"uint\":{d}}}}}", .{value});
        self.size += 1;
    }

    fn insert(self: *Linked, i: u64, value: u64) !void {
        try self.s.write(GET_LINKED ++ ",{{\"linked_array_list_insert\":{d}}},{{\"write\":{{\"uint\":{d}}}}}", .{ (i * 37) % self.size, value });
        self.size += 1;
    }

    fn remove(self: *Linked, i: u64) !void {
        try self.s.write(GET_LINKED ++ ",{{\"linked_array_list_remove\":{d}}}", .{(i * 53) % self.size});
        self.size -= 1;
    }

    fn set(self: *Linked, i: u64, value: u64) !void {
        try self.s.write(GET_LINKED ++ ",{{\"linked_array_list_get\":{d}}},{{\"write\":{{\"uint\":{d}}}}}", .{ (i * 11) % self.size, value });
    }

    fn slice(self: *Linked, offset: u64, size: u64) !void {
        try self.s.write(GET_LINKED ++ ",{{\"linked_array_list_slice\":{{\"offset\":{d},\"size\":{d}}}}}", .{ offset, size });
        self.size = size;
    }
};

fn deepLinked(w: *Io.Writer) !void {
    var s = try begin(w, "A linked array list, in transactions of hundreds of writes whose tree nodes are rewritten in place if the transaction made them and copied if not, with a freeze halfway through one and a concat at the end of it.");
    var list: Linked = .{ .s = &s, .size = 0 };

    try s.beginMoment();
    for (0..300) |i| try list.append(i);
    for (0..60) |i| try list.insert(i, 1000 + i);
    for (0..60) |i| try list.remove(i);
    for (0..40) |i| try list.set(i, 2000 + i);
    try list.slice(20, 200);
    for (0..40) |i| try list.append(3000 + i);
    try s.endMoment();
    const first_size = list.size;

    try s.beginMoment();
    for (0..100) |i| try list.append(4000 + i);
    for (0..40) |i| try list.insert(i + 60, 5000 + i);
    for (0..40) |i| try list.remove(i + 60);
    for (0..30) |i| try list.set(i + 40, 6000 + i);
    try s.endMoment();
    const second_size = list.size;

    try s.beginMoment();
    for (0..60) |i| try list.append(7000 + i);
    try s.freeze();
    for (0..60) |i| try list.insert(i + 100, 8000 + i);
    for (0..30) |i| try list.remove(i + 100);
    for (0..30) |i| try list.set(i + 70, 9000 + i);
    for (0..40) |i| try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"other\"}}}}}},\"linked_array_list_init\",\"linked_array_list_append\",{{\"write\":{{\"uint\":{d}}}}}", .{10000 + i});
    try s.op("{{\"op\":\"read_path_slot\",\"on\":\"m\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"other\"}}}}}}],\"as\":\"other\"}}", .{});
    try s.write(GET_LINKED ++ ",{{\"linked_array_list_concat\":{{\"list\":{{\"var\":\"other\"}}}}}}", .{});
    list.size += 40;
    try s.endMoment();
    const third_size = list.size;

    try s.beginMoment();
    for (0..50) |i| try list.append(11000 + i);
    for (0..20) |i| try list.remove(i + 130);
    // through a frozen cursor, which copies the nodes this transaction made before it
    try cloneFrozen(&s, "list", "list_clone");
    var clone_size = list.size;
    for (0..60) |i| {
        try s.op("{{\"op\":\"write_path\",\"on\":\"clone\",\"path\":[\"linked_array_list_init\",\"linked_array_list_append\",{{\"write\":{{\"uint\":{d}}}}}]}}", .{12000 + i});
        clone_size += 1;
    }
    for (0..20) |i| {
        try s.op("{{\"op\":\"write_path\",\"on\":\"clone\",\"path\":[\"linked_array_list_init\",{{\"linked_array_list_insert\":{d}}},{{\"write\":{{\"uint\":{d}}}}}]}}", .{ (i * 37) % clone_size, 13000 + i });
        clone_size += 1;
    }
    for (0..20) |i| {
        try s.op("{{\"op\":\"write_path\",\"on\":\"clone\",\"path\":[\"linked_array_list_init\",{{\"linked_array_list_remove\":{d}}}]}}", .{(i * 53) % clone_size});
        clone_size -= 1;
    }
    try s.endMoment();

    for ([_]u64{ first_size, second_size, third_size, list.size }, 0..) |size, moment| {
        try s.readMoment(@intCast(moment));
        try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list\"}}}}}}],\"as\":\"list\"}}", .{});
        try s.op("{{\"op\":\"count\",\"on\":\"list\",\"expect\":{d}}}", .{size});
    }
    try s.op("{{\"op\":\"read_path\",\"on\":\"list\",\"path\":[{{\"linked_array_list_get\":-1}}],\"as\":\"v\"}}", .{});
    try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":11049}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list_clone\"}}}}}}],\"as\":\"clone\"}}", .{});
    try s.op("{{\"op\":\"count\",\"on\":\"clone\",\"expect\":{d}}}", .{clone_size});
    try end(w);
}

// the deep transactions, with sorted maps and sets

/// 7919 and 1000 share no factor, so these are all different, and in no order. every
/// fifth one is too long to be in a slot.
fn writeSortedKey(buffer: []u8, i: u64) []const u8 {
    const base = (i * 7919) % 1000;
    return (if (base % 5 == 0)
        std.fmt.bufPrint(buffer, "a sorted key that is too long for a slot {d:0>4}", .{base})
    else
        std.fmt.bufPrint(buffer, "s{d:0>4}", .{base})) catch unreachable;
}

const GET_SORTED = "{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"sorted\"}}}}}},{{\"sorted_map_init\":{{}}}}";
const GET_SORTED_SET = "{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"set\"}}}}}},{{\"sorted_map_init\":{{\"set\":true}}}}";

fn sortedPut(s: *S, i: u64, value: u64) !void {
    var buffer: [64]u8 = undefined;
    try s.write(GET_SORTED ++ ",{{\"sorted_map_get\":{{\"value\":\"{s}\"}}}},{{\"write\":{{\"uint\":{d}}}}}", .{ writeSortedKey(&buffer, i), value });
}

fn sortedRemove(s: *S, i: u64) !void {
    var buffer: [64]u8 = undefined;
    try s.write(GET_SORTED ++ ",{{\"sorted_map_remove\":\"{s}\"}}", .{writeSortedKey(&buffer, i)});
}

fn setPut(s: *S, i: u64) !void {
    var buffer: [64]u8 = undefined;
    try s.write(GET_SORTED_SET ++ ",{{\"sorted_map_get\":{{\"key\":\"{s}\"}}}}", .{writeSortedKey(&buffer, i)});
}

fn setRemove(s: *S, i: u64) !void {
    var buffer: [64]u8 = undefined;
    try s.write(GET_SORTED_SET ++ ",{{\"sorted_map_remove\":\"{s}\"}}", .{writeSortedKey(&buffer, i)});
}

fn deepSorted(w: *Io.Writer) !void {
    var s = try begin(w, "A sorted map and a sorted set, in transactions of hundreds of writes whose tree nodes are rewritten in place if the transaction made them and copied if not, with a freeze halfway through one.");

    try s.beginMoment();
    for (0..300) |i| try sortedPut(&s, i, i);
    for (0..50) |i| try sortedPut(&s, i * 2, 1000 + i);
    for (100..160) |i| try sortedRemove(&s, i);
    for (100..120) |i| try sortedPut(&s, i, 2000 + i);
    for (0..150) |i| try setPut(&s, i);
    for (50..90) |i| try setRemove(&s, i);
    try s.endMoment();

    try s.beginMoment();
    for (300..400) |i| try sortedPut(&s, i, i);
    for (0..50) |i| try sortedPut(&s, i * 2, 3000 + i);
    for (200..240) |i| try sortedRemove(&s, i);
    for (150..200) |i| try setPut(&s, i);
    try s.endMoment();

    try s.beginMoment();
    for (400..460) |i| try sortedPut(&s, i, i);
    try s.freeze();
    for (400..430) |i| try sortedPut(&s, i, 4000 + i);
    for (240..260) |i| try sortedRemove(&s, i);
    for (90..100) |i| try setRemove(&s, i);
    // through a frozen cursor, which copies the nodes this transaction made before it
    try cloneFrozen(&s, "sorted", "sorted_clone");
    var buffer: [64]u8 = undefined;
    for (460..520) |i| try s.op("{{\"op\":\"write_path\",\"on\":\"clone\",\"path\":[{{\"sorted_map_init\":{{}}}},{{\"sorted_map_get\":{{\"value\":\"{s}\"}}}},{{\"write\":{{\"uint\":{d}}}}}]}}", .{ writeSortedKey(&buffer, i), i });
    for (260..280) |i| try s.op("{{\"op\":\"write_path\",\"on\":\"clone\",\"path\":[{{\"sorted_map_init\":{{}}}},{{\"sorted_map_remove\":\"{s}\"}}]}}", .{writeSortedKey(&buffer, i)});
    try s.endMoment();

    // 300 - 60 + 20, then 100 - 40 more, then 60 - 20 more, and 150 - 40, then 50 more, then 10 fewer
    for ([_][2]u64{ .{ 260, 110 }, .{ 320, 160 }, .{ 360, 150 } }, 0..) |counts, moment| {
        try s.readMoment(@intCast(moment));
        try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"sorted\"}}}}}}],\"as\":\"sorted\"}}", .{});
        try s.op("{{\"op\":\"count\",\"on\":\"sorted\",\"expect\":{d}}}", .{counts[0]});
        try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"set\"}}}}}}],\"as\":\"set\"}}", .{});
        try s.op("{{\"op\":\"count\",\"on\":\"set\",\"expect\":{d}}}", .{counts[1]});
    }
    try s.op("{{\"op\":\"read_path\",\"on\":\"sorted\",\"path\":[{{\"sorted_map_get\":{{\"value\":\"{s}\"}}}}],\"as\":\"v\"}}", .{writeSortedKey(&buffer, 401)});
    try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":4401,\"note\":\"written on either side of the freeze\"}}", .{});
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"sorted_clone\"}}}}}}],\"as\":\"clone\"}}", .{});
    try s.op("{{\"op\":\"count\",\"on\":\"clone\",\"expect\":400,\"note\":\"60 more than the map it's a clone of, and 20 fewer\"}}", .{});
    try end(w);
}

// iterators on collections that are several levels deep

const COUNT = 300;
const WALK = 20;
const STARTS = [_]i64{ 0, 1, 15, 16, 17, 100, 240, 255, 256, 257, 298, 299, -1, -2, -16, -17, -100, -256, -257, -300 };
const OUT_OF_RANGE = [_]i64{ 300, 301, 1300, -301, -1300 };

fn resolve(start: i64) u64 {
    return @intCast(if (start < 0) start + COUNT else start);
}

fn walkUints(s: *S, from: u64, steps: u64) !void {
    var value = from;
    for (0..steps) |_| {
        if (value == COUNT) break;
        try s.op("{{\"op\":\"next\",\"on\":\"it\",\"as\":\"e\",\"expect_null\":false}}", .{});
        try s.op("{{\"op\":\"read_uint\",\"on\":\"e\",\"expect\":{d}}}", .{value});
        value += 1;
    }
    if (value == COUNT) try s.op("{{\"op\":\"next\",\"on\":\"it\",\"expect_null\":true}}", .{});
}

/// an element appended and never written is empty in an array list, and an iterator skips
/// it. a linked array list marks it as written with nothing, and an iterator gives it.
fn walkHoles(s: *S, from: u64, comptime skipped: bool) !void {
    for (from..40) |i| {
        if (i % 3 == 0) {
            if (skipped) continue;
            try s.op("{{\"op\":\"next\",\"on\":\"it\",\"as\":\"e\",\"expect_null\":false}}", .{});
            try s.op("{{\"op\":\"slot\",\"on\":\"e\",\"expect\":{{\"tag\":\"none\",\"full\":true}}}}", .{});
        } else {
            try s.op("{{\"op\":\"next\",\"on\":\"it\",\"as\":\"e\",\"expect_null\":false}}", .{});
            try s.op("{{\"op\":\"read_uint\",\"on\":\"e\",\"expect\":{d}}}", .{i});
        }
    }
    try s.op("{{\"op\":\"next\",\"on\":\"it\",\"expect_null\":true}}", .{});
}

fn tiersOfList(s: *S, comptime list_init: []const u8, comptime list_append: []const u8, comptime holes_skipped: bool) !void {
    try s.beginMoment();
    for (0..COUNT) |i| {
        try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list\"}}}}}}," ++ list_init ++ "," ++ list_append ++ ",{{\"write\":{{\"uint\":{d}}}}}", .{i});
    }
    // appended and never written, and running over the end of a block
    for (0..40) |i| {
        if (i % 3 == 0) {
            try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"holes\"}}}}}}," ++ list_init ++ "," ++ list_append, .{});
        } else {
            try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"holes\"}}}}}}," ++ list_init ++ "," ++ list_append ++ ",{{\"write\":{{\"uint\":{d}}}}}", .{i});
        }
    }
    try s.endMoment();

    try s.readMoment(-1);
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"list\"}}}}}}],\"as\":\"list\"}}", .{});
    try s.op("{{\"op\":\"iterator\",\"on\":\"list\",\"as\":\"it\",\"note\":\"all of it\"}}", .{});
    try walkUints(s, 0, COUNT);
    for (STARTS) |start| {
        try s.op("{{\"op\":\"iterator\",\"on\":\"list\",\"from_index\":{d},\"as\":\"it\"}}", .{start});
        try walkUints(s, resolve(start), WALK);
    }
    for (OUT_OF_RANGE) |start| {
        try s.op("{{\"op\":\"iterator\",\"on\":\"list\",\"from_index\":{d},\"as\":\"it\"}}", .{start});
        try s.op("{{\"op\":\"next\",\"on\":\"it\",\"expect_null\":true}}", .{});
    }

    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"holes\"}}}}}}],\"as\":\"holes\"}}", .{});
    try s.op("{{\"op\":\"count\",\"on\":\"holes\",\"expect\":40}}", .{});
    try s.op("{{\"op\":\"iterator\",\"on\":\"holes\",\"as\":\"it\"}}", .{});
    try walkHoles(s, 0, holes_skipped);
    try s.op("{{\"op\":\"iterator\",\"on\":\"holes\",\"from_index\":15,\"as\":\"it\",\"note\":\"15 was never written\"}}", .{});
    try walkHoles(s, 15, holes_skipped);
}

fn iteratorTiers(w: *Io.Writer) !void {
    var s = try begin(w, "Iterators on an array list three levels deep, from either side of where each block ends, counting from either end, and past either end, and on a hash map 14 levels deep.");
    try tiersOfList(&s, "\"array_list_init\"", "\"array_list_append\"", true);

    // and a trie 14 levels deep. a slot's lowest nibble comes first, so at each level the
    // key that has a 0 there, and goes on down, comes before the one that has a 1
    try s.beginMoment();
    for (0..14) |level| try putDeep(&s, level, level);
    try s.endMoment();
    try s.readMoment(-1);
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"deep\"}}}}}}],\"as\":\"deep\"}}", .{});
    try s.op("{{\"op\":\"iterator\",\"on\":\"deep\",\"as\":\"it\"}}", .{});
    var level: u64 = 14;
    while (level > 0) {
        level -= 1;
        const hex = deepHash(level);
        try s.op("{{\"op\":\"next\",\"on\":\"it\",\"as\":\"e\",\"expect_null\":false}}", .{});
        try s.op("{{\"op\":\"read_key_value_pair\",\"on\":\"e\",\"value_as\":\"v\",\"expect_hash\":{{\"hex\":\"{s}\"}}}}", .{&hex});
        try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":{d}}}", .{level});
    }
    try s.op("{{\"op\":\"next\",\"on\":\"it\",\"expect_null\":true}}", .{});
    try end(w);
}

fn iteratorTiersLinked(w: *Io.Writer) !void {
    var s = try begin(w, "Iterators on a linked array list several levels deep, from either side of where a node might end, counting from either end, and past either end.");
    try tiersOfList(&s, "\"linked_array_list_init\"", "\"linked_array_list_append\"", false);
    try end(w);
}

fn walkSorted(s: *S, from: u64, steps: u64) !void {
    var value = from;
    for (0..steps) |_| {
        if (value == COUNT) break;
        try s.op("{{\"op\":\"next\",\"on\":\"it\",\"as\":\"e\",\"expect_null\":false}}", .{});
        try s.op("{{\"op\":\"read_key_value_pair\",\"on\":\"e\",\"key_as\":\"k\",\"value_as\":\"v\"}}", .{});
        try s.op("{{\"op\":\"read_bytes\",\"on\":\"k\",\"expect\":\"k{d:0>4}\"}}", .{value});
        try s.op("{{\"op\":\"read_uint\",\"on\":\"v\",\"expect\":{d}}}", .{value});
        value += 1;
    }
    if (value == COUNT) try s.op("{{\"op\":\"next\",\"on\":\"it\",\"expect_null\":true}}", .{});
}

fn iteratorTiersSorted(w: *Io.Writer) !void {
    var s = try begin(w, "Iterators and rank on a sorted map several levels deep: from an index, from a key that's there, and from a key between two others.");

    try s.beginMoment();
    // 7 and 300 share no factor, so this reaches every key, in no order
    for (0..COUNT) |i| {
        const key = (i * 7) % COUNT;
        try s.write("{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"sorted\"}}}}}},{{\"sorted_map_init\":{{}}}},{{\"sorted_map_get\":{{\"value\":\"k{d:0>4}\"}}}},{{\"write\":{{\"uint\":{d}}}}}", .{ key, key });
    }
    try s.endMoment();

    try s.readMoment(-1);
    try s.op("{{\"op\":\"read_path\",\"on\":\"moment\",\"path\":[{{\"hash_map_get\":{{\"value\":{{\"sha1\":\"sorted\"}}}}}}],\"as\":\"sorted\"}}", .{});
    try s.op("{{\"op\":\"iterator\",\"on\":\"sorted\",\"as\":\"it\",\"note\":\"all of it\"}}", .{});
    try walkSorted(&s, 0, COUNT);
    for (STARTS) |start| {
        try s.op("{{\"op\":\"iterator\",\"on\":\"sorted\",\"from_index\":{d},\"as\":\"it\"}}", .{start});
        try walkSorted(&s, resolve(start), WALK);
    }
    for (OUT_OF_RANGE) |start| {
        try s.op("{{\"op\":\"iterator\",\"on\":\"sorted\",\"from_index\":{d},\"as\":\"it\"}}", .{start});
        try s.op("{{\"op\":\"next\",\"on\":\"it\",\"expect_null\":true}}", .{});
    }

    // from a key, and how many keys come before it
    for ([_]u64{ 0, 1, 15, 16, 17, 100, 255, 256, 299 }) |key| {
        try s.op("{{\"op\":\"iterator\",\"on\":\"sorted\",\"from_key\":\"k{d:0>4}\",\"as\":\"it\"}}", .{key});
        try walkSorted(&s, key, WALK);
        // a key just after this one sorts before the next one
        try s.op("{{\"op\":\"iterator\",\"on\":\"sorted\",\"from_key\":\"k{d:0>4}x\",\"as\":\"it\"}}", .{key});
        try walkSorted(&s, key + 1, WALK);
    }
    for (0..COUNT) |key| {
        if (key % 7 != 0) continue;
        try s.op("{{\"op\":\"rank\",\"on\":\"sorted\",\"key\":\"k{d:0>4}\",\"expect\":{d}}}", .{ key, key });
        try s.op("{{\"op\":\"rank\",\"on\":\"sorted\",\"key\":\"k{d:0>4}x\",\"expect\":{d}}}", .{ key, key + 1 });
    }
    try end(w);
}

const Script = struct { name: []const u8, write: *const fn (*Io.Writer) anyerror!void };

const SCRIPTS = [_]Script{
    .{ .name = "deep-tries", .write = deepTries },
    .{ .name = "deep-linked", .write = deepLinked },
    .{ .name = "deep-sorted", .write = deepSorted },
    .{ .name = "iterator-tiers", .write = iteratorTiers },
    .{ .name = "iterator-tiers-linked", .write = iteratorTiersLinked },
    .{ .name = "iterator-tiers-sorted", .write = iteratorTiersSorted },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: longscripts <folder>\n", .{});
        std.process.exit(2);
    }
    try Io.Dir.cwd().createDirPath(io, args[1]);

    for (SCRIPTS) |script| {
        const path = try std.fs.path.join(arena, &.{ args[1], try std.mem.concat(arena, u8, &.{ script.name, ".json" }) });
        const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var writer = file.writerStreaming(io, &buffer);
        try script.write(&writer.interface);
        try writer.interface.flush();
    }
}
