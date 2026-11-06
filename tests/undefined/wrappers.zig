//! undefined-wrappers <case>
//!
//! The hazards in SCRIPT-FORMAT.md's "Two headers for one tree", through the collection
//! wrappers alone, as the README uses them, with nothing from the path API. Each case
//! is one transaction unless it says otherwise. It's separate from the scripts, which
//! can't hold a wrapper, so that it shows what a user of the library can reach.
//!
//! A case that gets to its end prints what it found and exits with 0. check.sh says
//! which cases should crash.

const std = @import("std");
const xitdb = @import("xitdb");

const DB = xitdb.Database(.memory, u160);
const RW = DB.Cursor(.read_write);
const Map = DB.HashMap(.read_write);
const Counted = DB.CountedHashMap(.read_write);
const Array = DB.ArrayList(.read_write);
const Linked = DB.LinkedArrayList(.read_write);
const Sorted = DB.SortedMap(.read_write);

fn h(comptime text: []const u8) u160 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(text, &digest, .{});
    return std.mem.readInt(u160, &digest, .big);
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

/// the README's way of cloning: a new key whose value starts as another collection's slot
fn cloneOf(moment: Map, key: u160, slot: xitdb.Slot, freeze: bool) !RW {
    var cursor = try moment.putCursor(key);
    try cursor.write(.{ .slot = slot });
    if (freeze) try cursor.freeze();
    return cursor;
}

fn threeIn(moment: Map, key: u160) !Linked {
    const list = try Linked.init(try moment.putCursor(key));
    try list.append(.{ .uint = 1 });
    try list.append(.{ .uint = 2 });
    try list.append(.{ .uint = 3 });
    return list;
}

const Case = enum {
    concat_then_clone,
    concat_two_wrappers,
    concat_slot_read_before,
    concat_old_map_wrapper,
    frozen_clone_append,
    frozen_clone_remove,
    frozen_clone_read,
    kept_across_transactions,
    sorted_frozen_clone_read,
    sorted_frozen_clone_remove,
    array_frozen_clone,
    array_frozen_clone_slice,
    hash_frozen_clone,
    counted_frozen_clone_remove,
    no_problem_without_freeze,
};

const Ctx = struct {
    case: Case,
    kept: *?Linked,

    pub fn run(self: Ctx, cursor: *RW) !void {
        const moment = try Map.init(cursor.*);
        switch (self.case) {
            // a concat, then the README's clone of the result, with no freeze anywhere.
            // the clone's init copies the header, and now they share a node it rewrites.
            .concat_then_clone => {
                const a = try threeIn(moment, h("a"));
                const b = try Linked.init(try moment.putCursor(h("b")));
                try b.concat(try a.slot());
                const c = try Linked.init(try cloneOf(moment, h("c"), try b.slot(), false));
                try c.remove(0);
                try c.remove(0);
                try b.append(.{ .uint = 4 });
            },
            // no slot read at all: the same list initialized twice, with the first
            // wrapper still in use. that's the second init a concat calls for.
            .concat_two_wrappers => {
                const a = try threeIn(moment, h("a"));
                const b = try Linked.init(try moment.putCursor(h("b")));
                try b.concat(try a.slot());
                const b2 = try Linked.init(try moment.putCursor(h("b")));
                try b2.remove(0);
                try b2.remove(0);
                try b.append(.{ .uint = 4 });
            },
            // a slot read before the concat, used after it
            .concat_slot_read_before => {
                const a = try threeIn(moment, h("a"));
                const b = try Linked.init(try moment.putCursor(h("b")));
                const before = try b.slot();
                try b.concat(try a.slot());
                const b2 = try Linked.init(try moment.putCursor(h("b")));
                try b2.remove(0);
                try b2.remove(0);
                const d = try Linked.init(try cloneOf(moment, h("d"), before, false));
                try d.append(.{ .uint = 4 });
            },
            // a read through a map wrapper from before the map was initialized again
            .concat_old_map_wrapper => {
                const a = try threeIn(moment, h("a"));
                const b = try Linked.init(try moment.putCursor(h("b")));
                try b.concat(try a.slot());
                const moment2 = try Map.init(cursor.*);
                const b2 = try Linked.init(try moment2.putCursor(h("b")));
                try b2.remove(0);
                try b2.remove(0);
                const stale = (try moment.getSlot(h("b"))).?;
                const c = try Linked.init(try moment2.putCursor(h("c")));
                try c.concat(stale);
                try c.append(.{ .uint = 4 });
            },
            // the README's frozen clone, and then a change to the original
            .frozen_clone_append => {
                const big = try threeIn(moment, h("big"));
                const c = try Linked.init(try cloneOf(moment, h("c"), try big.slot(), true));
                try big.remove(0);
                try big.remove(0);
                try c.append(.{ .uint = 4 });
            },
            .frozen_clone_remove => {
                const big = try threeIn(moment, h("big"));
                const c = try Linked.init(try cloneOf(moment, h("c"), try big.slot(), true));
                try big.remove(0);
                try big.remove(0);
                try c.remove(2);
            },
            .frozen_clone_read => {
                const big = try threeIn(moment, h("big"));
                const c = try Linked.init(try cloneOf(moment, h("c"), try big.slot(), true));
                try big.remove(0);
                try big.remove(0);
                say("count says {d}", .{try c.count()});
                _ = try c.getCursor(2);
            },
            // a wrapper kept from an earlier transaction: this is its second half
            .kept_across_transactions => {
                const kept = self.kept.*.?;
                try kept.append(.{ .uint = 4 });
                const b = try Linked.init(try moment.putCursor(h("a")));
                try b.remove(0);
                try b.remove(0);
                try b.remove(0);
                try kept.append(.{ .uint = 5 });
            },
            .sorted_frozen_clone_read => {
                const big = try Sorted.init(try moment.putCursor(h("big")));
                try big.put("a", .{ .uint = 1 });
                try big.put("b", .{ .uint = 2 });
                try big.put("c", .{ .uint = 3 });
                const c = try Sorted.init(try cloneOf(moment, h("c"), try big.slot(), true));
                _ = try big.remove("a");
                _ = try big.remove("b");
                say("count says {d}", .{try c.count()});
                _ = try c.getIndexKeyValuePair(2);
            },
            .sorted_frozen_clone_remove => {
                const big = try Sorted.init(try moment.putCursor(h("big")));
                const c = try Sorted.init(try cloneOf(moment, h("c"), try big.slot(), true));
                try big.put("a", .{ .uint = 1 });
                say("count says {d}", .{try c.count()});
                _ = try c.remove("a");
                say("and after removing what it shouldn't have seen, {d}", .{try c.count()});
            },
            // an array list's shape comes from its size, and it indexes by nibbles, so a
            // stale size can't overrun anything. what's left is the silent sharing.
            .array_frozen_clone => {
                const big = try Array.init(try moment.putCursor(h("big")));
                for (0..40) |i| try big.append(.{ .uint = i });
                const c = try Array.init(try cloneOf(moment, h("c"), try big.slot(), true));
                // more than a block's worth, so that they share a block below the root
                try big.put(3, .{ .uint = 999 });
                say("no crash so far. the clone sees the 999 written to the original afterward: {d}", .{try (try c.getCursor(3)).?.readUint()});
                try big.slice(2);
                for (0..40) |i| try big.append(.{ .uint = 100 + i });
                try c.append(.{ .uint = 5 });
                try c.put(3, .{ .uint = 7 });
                try c.slice(1);
                try c.append(.{ .uint = 6 });
                say("still no crash, with the original at {d} and the clone at {d}", .{ try big.count(), try c.count() });
            },
            .array_frozen_clone_slice => {
                const big = try Array.init(try moment.putCursor(h("big")));
                for (0..300) |i| try big.append(.{ .uint = i });
                const c = try Array.init(try cloneOf(moment, h("c"), try big.slot(), true));
                try big.slice(3);
                try big.append(.{ .uint = 1 });
                for (0..300) |i| {
                    const found = try c.getCursor(@intCast(i));
                    if (found) |value| _ = try value.readUint();
                }
                try c.append(.{ .uint = 2 });
                say("no crash, with the clone at {d} and the original at {d}", .{ try c.count(), try big.count() });
            },
            .hash_frozen_clone => {
                const big = try Map.init(try moment.putCursor(h("big")));
                // these share their lowest nibble, so that there's an index block to share
                try big.put(0x01, .{ .uint = 1 });
                try big.put(0x11, .{ .uint = 2 });
                const c = try Map.init(try cloneOf(moment, h("c"), try big.slot(), true));
                try big.put(0x21, .{ .uint = 3 });
                _ = try big.remove(0x01);
                _ = try c.remove(0x11);
                try c.put(0x31, .{ .uint = 4 });
                say("no crash. the clone sees the 0x21 written to the original afterward: {}", .{(try c.getCursor(0x21)) != null});
            },
            .counted_frozen_clone_remove => {
                const big = try Counted.init(try moment.putCursor(h("big")));
                try big.put(0x01, .{ .uint = 1 });
                try big.put(0x11, .{ .uint = 2 });
                const c = try Counted.init(try cloneOf(moment, h("c"), try big.map.cursor.slot(), true));
                try big.put(0x21, .{ .uint = 3 });
                _ = try c.remove(0x01);
                _ = try c.remove(0x11);
                _ = try c.remove(0x21);
                say("the clone counts {d}", .{try c.count()});
            },
            // the control: a clone with no freeze and no concat is one list with two names
            .no_problem_without_freeze => {
                const big = try threeIn(moment, h("big"));
                const c = try Linked.init(try cloneOf(moment, h("c"), try big.slot(), false));
                try big.remove(0);
                try big.remove(0);
                try c.append(.{ .uint = 4 });
                say("no crash, and both say {d} and {d}", .{ try big.count(), try c.count() });
            },
        }
    }
};

const Keep = struct {
    kept: *?Linked,

    pub fn run(self: Keep, cursor: *RW) !void {
        const moment = try Map.init(cursor.*);
        self.kept.* = try threeIn(moment, h("a"));
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        for (std.enums.values(Case)) |c| say("{s}", .{@tagName(c)});
        std.process.exit(2);
    }
    const case = std.meta.stringToEnum(Case, args[1]) orelse {
        say("no such case", .{});
        std.process.exit(2);
    };

    var buffer = std.Io.Writer.Allocating.init(init.gpa);
    defer buffer.deinit();
    var db = try DB.init(init.io, .{ .buffer = &buffer });
    const history = try Array.init(db.rootCursor());

    var kept: ?Linked = null;
    if (case == .kept_across_transactions) {
        try history.appendContext(.{ .slot = try history.getSlot(-1) }, Keep{ .kept = &kept });
    }
    try history.appendContext(.{ .slot = try history.getSlot(-1) }, Ctx{ .case = case, .kept = &kept });
    say("finished", .{});
}
