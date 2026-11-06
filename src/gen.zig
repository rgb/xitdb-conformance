//! gen <seed> <out.script> [--ops <top-level ops>] [--reads] [--compact]
//!
//! Writes a valid random script. The same seed always gives the same script.
//!
//! With --reads the script also has iterators, streams and reads into buffers along
//! the way. They have a random source of their own, so that they change nothing else
//! that's written, and the same seed gives the same writes with or without them. Reads
//! don't change bytes, so the two scripts should give the same file, and the gate
//! checks that they do.
//!
//! With --compact the script ends by compacting what it made into a new database, which
//! this doesn't do itself, as nothing it writes depends on the result. `run` does it, and
//! the target is an expected file like any other.
//!
//! The model of the database that a generator needs is the database: this drives
//! the real engine as it writes, in memory. It looks at what's there to choose
//! sensible next steps, and what the engine returns is what goes in the script as
//! an expectation, or as `expect_error`. So a script pins what Zig does, including
//! aliasing, freeze points and overwritten committed bytes, which a separate model
//! would have to get right first. `run` then executes the text it wrote, which
//! checks this code too: an expectation that doesn't hold there is a bug in one of them.
//!
//! This keeps away from what SCRIPT-FORMAT.md calls undefined uses.

const std = @import("std");
const xitdb = @import("xitdb");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const SCRIPT_FORMAT = "xitdb-script/1";
const MAX_DEPTH = 4;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("gen: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn oom() noreturn {
    fail("out of memory", .{});
}

/// splitmix64, written out so that a seed gives the same script whatever the standard library does
const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn below(self: *Rng, n: u64) u64 {
        return self.next() % n;
    }

    fn chance(self: *Rng, percent: u64) bool {
        return self.below(100) < percent;
    }
};

fn expectable(err: anyerror) bool {
    return switch (err) {
        error.KeyNotFound,
        error.UnexpectedTag,
        error.WriteNotAllowed,
        error.CursorNotWriteable,
        error.ExpectedTxStart,
        error.NestedTopLevelWrite,
        error.PathPartMustBeAtEnd,
        error.ScriptAbort,
        => true,
        else => false,
    };
}

fn Gen(comptime HashInt: type) type {
    return struct {
        const Self = @This();
        const DB = xitdb.Database(.memory, HashInt);
        const RW = DB.Cursor(.read_write);
        const RO = DB.Cursor(.read_only);
        const Slot = xitdb.Slot;
        const Tag = xitdb.Tag;
        const Part = DB.PathPart(Ctx);
        const Data = DB.WriteableData;
        const HASH_SIZE = @bitSizeOf(HashInt) / 8;
        const TRAILER_SIZE = 25;

        const Ctx = struct {
            g: *Self,
            name: []const u8,

            pub fn run(self: Ctx, cursor: *RW) anyerror!void {
                const g = self.g;
                const index = g.kept.items.len;
                g.kept.append(g.arena, .{ .name = self.name, .cursor = cursor.* }) catch oom();
                g.enter();
                defer g.leave();
                try g.body(index);
                cursor.* = g.kept.items[index].cursor;
            }
        };

        const Named = struct { name: []const u8, cursor: RW };
        const Commit = struct { size: u64, root: [9]u8 };

        const PathB = struct {
            parts: std.ArrayList(Part) = .empty,
            text: std.ArrayList(u8) = .empty,
            has_ctx: bool = false,
        };

        const Key = struct { hash: HashInt, json: []const u8 };
        const SortedKey = struct { bytes: []const u8, json: []const u8 };
        const Value = struct { data: Data, json: []const u8 };

        io: Io,
        arena: Allocator,
        rng: Rng,
        w: *Io.Writer,
        buffer: *Io.Writer.Allocating,
        db: DB = undefined,
        read_only_allowed: bool,
        // what a script may use, so that some can run before a port has every collection
        linked_allowed: bool,
        sorted_allowed: bool,

        kept: std.ArrayList(Named) = .empty,
        commits: std.ArrayList(Commit) = .empty,
        names: usize = 0,
        tx_kept_start: usize = 0,
        depth: usize = 0,
        has_ops: [MAX_DEPTH + 3]bool = @splat(false),
        history: bool = true,
        // whether the current top-level op failed, so that what it bound is gone
        top_failed: bool = false,
        // whether this transaction may have written into committed bytes. what it wrote
        // can point at data in this transaction, so if that were rolled back, committed
        // data would be left pointing at nothing, and it mustn't fail from here on. for
        // the same reason, the root header can't be set back past a commit that did this.
        tx_dirty: bool = false,
        first_lost_commit: usize = 0,
        // a frozen cursor copies a collection's header, and only the nodes it writes to,
        // while an unfrozen one goes on rewriting those same nodes in place. when two
        // slots hold one collection made in this transaction, that leaves one header
        // disagreeing with its tree, which panics the engine, or worse in a release build.
        // so once both of these have happened, everything gets frozen, which is safe.
        tx_cloned: bool = false,
        tx_frozen_cursor: bool = false,
        tx_concat: bool = false,
        // cursors before this one in `kept` are not used any more in this transaction
        first_safe_kept: usize = 0,
        // whether to add the reads that --reads adds, what they choose with, and what they call things
        reads: bool,
        read_rng: Rng,
        read_names: usize = 1_000_000_000,

        // names

        fn fresh(self: *Self, comptime prefix: []const u8) []const u8 {
            self.names += 1;
            return std.fmt.allocPrint(self.arena, prefix ++ "{d}", .{self.names}) catch oom();
        }

        fn fmt(self: *Self, comptime f: []const u8, args: anytype) []const u8 {
            return std.fmt.allocPrint(self.arena, f, args) catch oom();
        }

        // writing the script as it runs

        fn enter(self: *Self) void {
            self.depth += 1;
            self.has_ops[self.depth] = false;
        }

        fn leave(self: *Self) void {
            self.depth -= 1;
        }

        fn beginOp(self: *Self) anyerror!void {
            // if the engine crashes, this leaves a script up to where it happened
            try self.w.flush();
            if (self.has_ops[self.depth]) try self.w.writeAll(",");
            self.has_ops[self.depth] = true;
            try self.w.writeAll("\n");
            for (0..(self.depth + 2) * 2) |_| try self.w.writeAll(" ");
        }

        fn endOp(self: *Self) anyerror!void {
            try self.w.writeAll("}");
        }

        fn hex(self: *Self, bytes: []const u8) []const u8 {
            const out = self.arena.alloc(u8, bytes.len * 2) catch oom();
            const digits = "0123456789abcdef";
            for (bytes, 0..) |b, i| {
                out[i * 2] = digits[b >> 4];
                out[i * 2 + 1] = digits[b & 15];
            }
            return out;
        }

        // a bytes value as it's written in a script
        fn bytesJson(self: *Self, bytes: []const u8) []const u8 {
            for (bytes) |b| {
                switch (b) {
                    'a'...'z', 'A'...'Z', '0'...'9', ' ', '-' => {},
                    else => return self.fmt("{{\"hex\":\"{s}\"}}", .{self.hex(bytes)}),
                }
            }
            return self.fmt("\"{s}\"", .{bytes});
        }

        fn add(self: *Self, p: *PathB, part: Part, json: []const u8) void {
            p.parts.append(self.arena, part) catch oom();
            if (p.text.items.len > 0) p.text.appendSlice(self.arena, ",") catch oom();
            p.text.appendSlice(self.arena, json) catch oom();
        }

        /// what an error does to the op that raised it. returns true if it goes on
        /// upward, and otherwise says it was expected.
        fn noteError(self: *Self, err: anyerror) anyerror!bool {
            if (!expectable(err)) fail("the engine raised {s}, which a script can't expect", .{@errorName(err)});
            if (self.depth > 0 and !self.tx_dirty and self.rng.chance(15)) return true;
            try self.w.print(",\"expect_error\":\"{s}\"", .{@errorName(err)});
            if (self.depth == 0) self.top_failed = true;
            return false;
        }

        // values

        fn key(self: *Self) Key {
            const i = self.rng.below(24);
            var bytes: [HASH_SIZE]u8 = @splat(0);
            if (i < 16) {
                var digest: [20]u8 = undefined;
                const text = self.fmt("k{d}", .{i});
                std.crypto.hash.Sha1.hash(text, &digest, .{});
                @memcpy(bytes[0..@min(HASH_SIZE, 20)], digest[0..@min(HASH_SIZE, 20)]);
                const hash = std.mem.readInt(HashInt, &bytes, .big);
                if (HASH_SIZE == 20 and i % 4 != 0) return .{ .hash = hash, .json = self.fmt("{{\"sha1\":\"{s}\"}}", .{text}) };
                return .{ .hash = hash, .json = self.fmt("{{\"hex\":\"{s}\"}}", .{self.hex(&bytes)}) };
            }
            // these share their lowest nibble, so that the trie grows levels
            bytes[HASH_SIZE - 1] = @intCast(((i - 16) << 4) | 1);
            return .{ .hash = std.mem.readInt(HashInt, &bytes, .big), .json = self.fmt("{{\"hex\":\"{s}\"}}", .{self.hex(&bytes)}) };
        }

        fn sortedKey(self: *Self) SortedKey {
            const i = self.rng.below(40);
            const bytes = if (i % 11 == 0)
                self.arena.dupe(u8, &.{ @intCast(i), 0, @intCast(i) }) catch oom()
            else if (i % 7 == 0)
                self.fmt("a sorted key that is too long for a slot {d}", .{i})
            else
                self.fmt("s{d}", .{i});
            return .{ .bytes = bytes, .json = self.bytesJson(bytes) };
        }

        fn randomBytes(self: *Self, len: usize) []const u8 {
            const out = self.arena.alloc(u8, len) catch oom();
            for (out) |*b| b.* = 'a' + @as(u8, @intCast(self.rng.below(26)));
            return out;
        }

        fn value(self: *Self) Value {
            switch (self.rng.below(11)) {
                0 => {
                    const n: u64 = if (self.rng.chance(10)) std.math.maxInt(u64) else self.rng.below(1000);
                    return .{ .data = .{ .uint = n }, .json = self.fmt("{{\"uint\":{d}}}", .{n}) };
                },
                1 => {
                    const n: i64 = @as(i64, @intCast(self.rng.below(2000))) - 1000;
                    return .{ .data = .{ .int = n }, .json = self.fmt("{{\"int\":{d}}}", .{n}) };
                },
                2 => {
                    const bits = self.rng.next();
                    return .{ .data = .{ .float = @bitCast(bits) }, .json = self.fmt("{{\"float\":\"{x:0>16}\"}}", .{bits}) };
                },
                3, 4 => {
                    const bytes = self.randomBytes(self.rng.below(9));
                    return .{ .data = .{ .bytes = bytes }, .json = self.fmt("{{\"bytes\":{s}}}", .{self.bytesJson(bytes)}) };
                },
                5, 6 => {
                    const bytes = self.randomBytes(9 + self.rng.below(50));
                    return .{ .data = .{ .bytes = bytes }, .json = self.fmt("{{\"bytes\":{s}}}", .{self.bytesJson(bytes)}) };
                },
                7 => {
                    const bytes = self.arena.dupe(u8, &.{ 'a', 0, @intCast(self.rng.below(256)) }) catch oom();
                    return .{ .data = .{ .bytes = bytes }, .json = self.fmt("{{\"bytes\":{s}}}", .{self.bytesJson(bytes)}) };
                },
                8 => {
                    const bytes = self.randomBytes(self.rng.below(7));
                    const tag = self.randomBytes(2);
                    return .{ .data = .{ .bytes_object = .{ .value = bytes, .format_tag = tag[0..2].* } }, .json = self.fmt("{{\"bytes_object\":{{\"value\":{s},\"format_tag\":{s}}}}}", .{ self.bytesJson(bytes), self.bytesJson(tag) }) };
                },
                9 => {
                    const bytes = self.randomBytes(7 + self.rng.below(40));
                    const tag = self.randomBytes(2);
                    return .{ .data = .{ .bytes_object = .{ .value = bytes, .format_tag = tag[0..2].* } }, .json = self.fmt("{{\"bytes_object\":{{\"value\":{s},\"format_tag\":{s}}}}}", .{ self.bytesJson(bytes), self.bytesJson(tag) }) };
                },
                else => return .{ .data = .{ .slot = null }, .json = "{\"slot\":null}" },
            }
        }

        fn indexIn(self: *Self, size: u64) i65 {
            if (size == 0) return 0;
            const i: i65 = @intCast(self.rng.below(size));
            return if (self.rng.chance(30)) i - @as(i65, @intCast(size)) else i;
        }

        // path parts

        fn addInit(self: *Self, p: *PathB, tag: Tag) void {
            switch (tag) {
                .array_list => self.add(p, .array_list_init, "\"array_list_init\""),
                .linked_array_list => self.add(p, .linked_array_list_init, "\"linked_array_list_init\""),
                .hash_map => self.add(p, .{ .hash_map_init = .{} }, "{\"hash_map_init\":{}}"),
                .hash_set => self.add(p, .{ .hash_map_init = .{ .set = true } }, "{\"hash_map_init\":{\"set\":true}}"),
                .counted_hash_map => self.add(p, .{ .hash_map_init = .{ .counted = true } }, "{\"hash_map_init\":{\"counted\":true}}"),
                .counted_hash_set => self.add(p, .{ .hash_map_init = .{ .counted = true, .set = true } }, "{\"hash_map_init\":{\"counted\":true,\"set\":true}}"),
                .sorted_map => self.add(p, .{ .sorted_map_init = .{} }, "{\"sorted_map_init\":{}}"),
                .sorted_set => self.add(p, .{ .sorted_map_init = .{ .set = true } }, "{\"sorted_map_init\":{\"set\":true}}"),
                else => unreachable,
            }
        }

        // nearly always: skipping it writes into what's already committed, which is
        // defined (SCRIPT-FORMAT.md section 11), and worth having now and then
        fn maybeInit(self: *Self, p: *PathB, tag: Tag) void {
            // a path at the top level is a whole transaction, which can still fail after this.
            // the trees are left out, because a later init would copy their committed header
            // while it points at a node from this transaction, which gives two headers one tree
            const hash_or_array = tag == .hash_map or tag == .counted_hash_map or tag == .hash_set or tag == .counted_hash_set or tag == .array_list;
            if (hash_or_array and self.depth > 0 and self.rng.chance(3)) {
                self.tx_dirty = true;
            } else {
                self.addInit(p, tag);
            }
        }

        fn addHashGet(self: *Self, p: *PathB, target: enum { value, key, kv_pair }) void {
            const k = self.key();
            switch (target) {
                .value => self.add(p, .{ .hash_map_get = .{ .value = k.hash } }, self.fmt("{{\"hash_map_get\":{{\"value\":{s}}}}}", .{k.json})),
                .key => self.add(p, .{ .hash_map_get = .{ .key = k.hash } }, self.fmt("{{\"hash_map_get\":{{\"key\":{s}}}}}", .{k.json})),
                .kv_pair => self.add(p, .{ .hash_map_get = .{ .kv_pair = k.hash } }, self.fmt("{{\"hash_map_get\":{{\"kv_pair\":{s}}}}}", .{k.json})),
            }
        }

        fn addSortedGet(self: *Self, p: *PathB, target: enum { value, key, kv_pair }) void {
            const k = self.sortedKey();
            switch (target) {
                .value => self.add(p, .{ .sorted_map_get = .{ .value = k.bytes } }, self.fmt("{{\"sorted_map_get\":{{\"value\":{s}}}}}", .{k.json})),
                .key => self.add(p, .{ .sorted_map_get = .{ .key = k.bytes } }, self.fmt("{{\"sorted_map_get\":{{\"key\":{s}}}}}", .{k.json})),
                .kv_pair => self.add(p, .{ .sorted_map_get = .{ .kv_pair = k.bytes } }, self.fmt("{{\"sorted_map_get\":{{\"kv_pair\":{s}}}}}", .{k.json})),
            }
        }

        fn addArrayGet(self: *Self, p: *PathB, i: i65) void {
            self.add(p, .{ .array_list_get = i }, self.fmt("{{\"array_list_get\":{d}}}", .{i}));
        }

        fn addLinkedGet(self: *Self, p: *PathB, i: i65) void {
            self.add(p, .{ .linked_array_list_get = i }, self.fmt("{{\"linked_array_list_get\":{d}}}", .{i}));
        }

        fn addWrite(self: *Self, p: *PathB) void {
            const v = self.value();
            self.add(p, .{ .write = v.data }, self.fmt("{{\"write\":{s}}}", .{v.json}));
        }

        fn addWriteBytes(self: *Self, p: *PathB) void {
            const bytes = self.randomBytes(1 + self.rng.below(14));
            self.add(p, .{ .write = .{ .bytes = bytes } }, self.fmt("{{\"write\":{{\"bytes\":{s}}}}}", .{self.bytesJson(bytes)}));
        }

        // looking at what's there, through the engine

        fn peekTag(cursor: anytype, parts: []const Part) Tag {
            const slot = cursor.readPathSlot(Ctx, parts) catch return .none;
            return if (slot) |s| s.tag else .none;
        }

        fn peekCount(cursor: anytype, parts: []const Part) u64 {
            const found = cursor.readPath(Ctx, parts) catch return 0;
            const c = found orelse return 0;
            return c.count() catch 0;
        }

        /// walks down into what's there, adding the parts a write needs, with `reads` as
        /// the same path for looking at things. returns the tag of the slot it stopped at.
        fn walk(self: *Self, cursor: anytype, p: *PathB, reads: *std.ArrayList(Part)) Tag {
            var levels: usize = 0;
            while (true) {
                const tag = peekTag(cursor, reads.items);
                if (levels >= 4 or !self.rng.chance(60)) return tag;
                var step: PathB = .{};
                switch (tag) {
                    .hash_map, .counted_hash_map => {
                        self.maybeInit(p, tag);
                        self.addHashGet(&step, .value);
                    },
                    .array_list => {
                        const size = peekCount(cursor, reads.items);
                        if (size == 0) return tag;
                        self.maybeInit(p, tag);
                        self.addArrayGet(&step, self.indexIn(size));
                    },
                    .linked_array_list => {
                        const size = peekCount(cursor, reads.items);
                        if (size == 0) return tag;
                        self.maybeInit(p, tag);
                        self.addLinkedGet(&step, self.indexIn(size));
                    },
                    .sorted_map => {
                        self.maybeInit(p, tag);
                        self.addSortedGet(&step, .value);
                    },
                    else => return tag,
                }
                self.add(p, step.parts.items[0], step.text.items);
                reads.append(self.arena, step.parts.items[0]) catch oom();
                levels += 1;
            }
        }

        /// adds what to do at the end of a walk
        fn finish(self: *Self, cursor: anytype, p: *PathB, reads: []const Part, tag: Tag) void {
            // now and then, something that doesn't fit, for the error it raises. it can
            // fit after all, and with no init part before it, that writes into committed bytes
            if (self.rng.chance(3)) {
                if (self.depth > 0) self.tx_dirty = true;
                switch (self.rng.below(5)) {
                    0 => self.add(p, .array_list_append, "\"array_list_append\""),
                    // not on a tree of its own kind, which would be a skipped init (see maybeInit)
                    1 => if (self.linked_allowed and tag != .linked_array_list) self.add(p, .linked_array_list_append, "\"linked_array_list_append\"") else self.addArrayGet(p, 99),
                    2 => self.addHashGet(p, .value),
                    3 => if (self.sorted_allowed and tag != .sorted_map and tag != .sorted_set) self.addSortedGet(p, .value) else self.addHashGet(p, .value),
                    else => {
                        if (self.sorted_allowed and self.rng.chance(50)) {
                            self.add(p, .{ .sorted_map_get_index = 0 }, "{\"sorted_map_get_index\":0}");
                        } else {
                            self.addArrayGet(p, 99);
                        }
                    },
                }
                return;
            }
            switch (tag) {
                .hash_map, .counted_hash_map => {
                    self.maybeInit(p, tag);
                    const r = self.rng.below(10);
                    if (r < 7) {
                        self.addHashGet(p, .value);
                        self.addWrite(p);
                    } else if (r < 9) {
                        const k = self.key();
                        self.add(p, .{ .hash_map_remove = k.hash }, self.fmt("{{\"hash_map_remove\":{s}}}", .{k.json}));
                    } else {
                        self.addHashGet(p, .key);
                        self.addWriteBytes(p);
                    }
                },
                .hash_set, .counted_hash_set => {
                    self.maybeInit(p, tag);
                    if (self.rng.chance(80)) {
                        self.addHashGet(p, .key);
                        self.addWriteBytes(p);
                    } else {
                        const k = self.key();
                        self.add(p, .{ .hash_map_remove = k.hash }, self.fmt("{{\"hash_map_remove\":{s}}}", .{k.json}));
                    }
                },
                .array_list => {
                    const size = peekCount(cursor, reads);
                    self.maybeInit(p, tag);
                    const r = self.rng.below(10);
                    if (r < 6 or size == 0) {
                        self.add(p, .array_list_append, "\"array_list_append\"");
                        self.addWrite(p);
                    } else if (r < 8) {
                        self.addArrayGet(p, self.indexIn(size));
                        self.addWrite(p);
                    } else {
                        const new_size = self.rng.below(size + 2);
                        self.add(p, .{ .array_list_slice = .{ .size = new_size } }, self.fmt("{{\"array_list_slice\":{{\"size\":{d}}}}}", .{new_size}));
                    }
                },
                .linked_array_list => {
                    const size = peekCount(cursor, reads);
                    self.maybeInit(p, tag);
                    const r = self.rng.below(100);
                    if (r < 40 or size == 0) {
                        self.add(p, .linked_array_list_append, "\"linked_array_list_append\"");
                        self.addWrite(p);
                    } else if (r < 55) {
                        const i = self.indexIn(size);
                        self.add(p, .{ .linked_array_list_insert = i }, self.fmt("{{\"linked_array_list_insert\":{d}}}", .{i}));
                        self.addWrite(p);
                    } else if (r < 70) {
                        const i = self.indexIn(size);
                        self.add(p, .{ .linked_array_list_remove = i }, self.fmt("{{\"linked_array_list_remove\":{d}}}", .{i}));
                    } else if (r < 85) {
                        self.addLinkedGet(p, self.indexIn(size));
                        self.addWrite(p);
                    } else {
                        const offset = self.rng.below(size + 1);
                        const new_size = self.rng.below(size - offset + 2);
                        self.add(p, .{ .linked_array_list_slice = .{ .offset = offset, .size = new_size } }, self.fmt("{{\"linked_array_list_slice\":{{\"offset\":{d},\"size\":{d}}}}}", .{ offset, new_size }));
                    }
                },
                .sorted_map => {
                    self.maybeInit(p, tag);
                    const r = self.rng.below(10);
                    if (r < 7) {
                        self.addSortedGet(p, .value);
                        self.addWrite(p);
                    } else if (r < 9) {
                        const k = self.sortedKey();
                        self.add(p, .{ .sorted_map_remove = k.bytes }, self.fmt("{{\"sorted_map_remove\":{s}}}", .{k.json}));
                    } else {
                        self.addSortedGet(p, .kv_pair);
                    }
                },
                .sorted_set => {
                    self.maybeInit(p, tag);
                    if (self.rng.chance(80)) {
                        self.addSortedGet(p, .key);
                    } else {
                        const k = self.sortedKey();
                        self.add(p, .{ .sorted_map_remove = k.bytes }, self.fmt("{{\"sorted_map_remove\":{s}}}", .{k.json}));
                    }
                },
                .none => {
                    switch (self.rng.below(16)) {
                        0, 1, 2, 3, 4, 5 => self.addWrite(p),
                        6, 7 => {
                            self.addInit(p, .hash_map);
                            self.addHashGet(p, .value);
                            self.addWrite(p);
                        },
                        8 => {
                            self.addInit(p, .counted_hash_map);
                            self.addHashGet(p, .value);
                            self.addWrite(p);
                        },
                        9 => {
                            self.addInit(p, if (self.rng.chance(50)) .hash_set else .counted_hash_set);
                            self.addHashGet(p, .key);
                            self.addWriteBytes(p);
                        },
                        10, 11 => {
                            self.addInit(p, .array_list);
                            self.add(p, .array_list_append, "\"array_list_append\"");
                            self.addWrite(p);
                        },
                        12 => {
                            if (self.linked_allowed) {
                                self.addInit(p, .linked_array_list);
                                self.add(p, .linked_array_list_append, "\"linked_array_list_append\"");
                            } else {
                                self.addInit(p, .array_list);
                                self.add(p, .array_list_append, "\"array_list_append\"");
                            }
                            self.addWrite(p);
                        },
                        13, 14 => {
                            if (self.sorted_allowed) {
                                self.addInit(p, .sorted_map);
                                self.addSortedGet(p, .value);
                            } else {
                                self.addInit(p, .hash_map);
                                self.addHashGet(p, .value);
                            }
                            self.addWrite(p);
                        },
                        else => {
                            if (self.sorted_allowed) {
                                self.addInit(p, .sorted_set);
                                self.addSortedGet(p, .key);
                            } else {
                                self.addWrite(p);
                            }
                        },
                    }
                },
                else => self.addWrite(p),
            }
        }

        // ops

        /// the cursor at `index`, by value
        fn at(self: *Self, index: usize) Named {
            return self.kept.items[index];
        }

        fn writePath(self: *Self, on_name: []const u8, cursor: RW, p: *PathB, bind: bool) anyerror!void {
            try self.beginOp();
            try self.w.print("{{\"op\":\"write_path\",\"on\":\"{s}\",\"path\":[{s}", .{ on_name, p.text.items });
            try self.w.flush();
            const result = cursor.writePath(Ctx, p.parts.items);
            if (p.has_ctx) try self.w.writeAll("]}}");
            try self.w.writeAll("]");
            if (result) |next| {
                if (bind) {
                    const name = self.fresh("c");
                    self.kept.append(self.arena, .{ .name = name, .cursor = next }) catch oom();
                    try self.w.print(",\"as\":\"{s}\"", .{name});
                }
                try self.endOp();
            } else |err| {
                const upward = try self.noteError(err);
                try self.endOp();
                if (upward) return err;
            }
        }

        fn addCtx(self: *Self, p: *PathB) void {
            const name = self.fresh("c");
            self.add(p, .{ .ctx = .{ .g = self, .name = name } }, self.fmt("{{\"ctx\":{{\"as\":\"{s}\",\"ops\":[", .{name}));
            p.has_ctx = true;
        }

        /// a write somewhere under a cursor, chosen by what's there
        fn writeSomething(self: *Self, index: usize) anyerror!void {
            const on = self.at(index);
            var p: PathB = .{};
            var reads: std.ArrayList(Part) = .empty;
            const tag = self.walk(on.cursor, &p, &reads);
            self.finish(on.cursor, &p, reads.items, tag);
            try self.writePath(on.name, on.cursor, &p, self.rng.chance(20));
        }

        /// a burst of appends and puts, enough to make the trees grow a level, and then
        /// the operations that are hardest on a tree that has grown
        fn burst(self: *Self, index: usize) anyerror!void {
            const on = self.at(index);
            const tag = peekTag(on.cursor, &.{});
            if (tag != .hash_map and tag != .counted_hash_map) return;

            var choices: [3]Tag = @splat(.array_list);
            var choice_count: usize = 1;
            if (self.linked_allowed) {
                choices[choice_count] = .linked_array_list;
                choice_count += 1;
            }
            if (self.sorted_allowed) {
                choices[choice_count] = .sorted_map;
                choice_count += 1;
            }
            const collection = choices[@intCast(self.rng.below(choice_count))];

            // a key with nothing under it, or the same kind of collection, since
            // otherwise each step of the burst just fails in the same way
            var k = self.key();
            var hash_get = Part{ .hash_map_get = .{ .value = k.hash } };
            for (0..8) |_| {
                const existing = peekTag(on.cursor, &[_]Part{hash_get});
                if (existing == .none or existing == collection) break;
                k = self.key();
                hash_get = .{ .hash_map_get = .{ .value = k.hash } };
            } else return;
            const get_json = self.fmt("{{\"hash_map_get\":{{\"value\":{s}}}}}", .{k.json});

            // now and then enough for a third level in the array list's trie
            const big = collection == .array_list and self.rng.chance(4);
            const n = if (big) 257 + self.rng.below(16) else 17 + self.rng.below(24);
            for (0..n) |_| {
                var p: PathB = .{};
                self.addInit(&p, tag);
                self.add(&p, hash_get, get_json);
                self.addInit(&p, collection);
                switch (collection) {
                    .array_list => self.add(&p, .array_list_append, "\"array_list_append\""),
                    .linked_array_list => self.add(&p, .linked_array_list_append, "\"linked_array_list_append\""),
                    else => self.addSortedGet(&p, .value),
                }
                if (big) {
                    const i = self.rng.below(1000);
                    self.add(&p, .{ .write = .{ .uint = i } }, self.fmt("{{\"write\":{{\"uint\":{d}}}}}", .{i}));
                } else {
                    self.addWrite(&p);
                }
                try self.writePath(on.name, on.cursor, &p, false);
            }

            const reads = [_]Part{hash_get};
            for (0..2 + self.rng.below(7)) |_| {
                const size = peekCount(on.cursor, &reads);
                var p: PathB = .{};
                self.addInit(&p, tag);
                self.add(&p, hash_get, get_json);
                self.addInit(&p, collection);
                switch (collection) {
                    .array_list => switch (self.rng.below(4)) {
                        0 => {
                            const new_size = self.rng.below(size + 1);
                            self.add(&p, .{ .array_list_slice = .{ .size = new_size } }, self.fmt("{{\"array_list_slice\":{{\"size\":{d}}}}}", .{new_size}));
                        },
                        1 => {
                            self.addArrayGet(&p, self.indexIn(size));
                            self.addWrite(&p);
                        },
                        else => {
                            self.add(&p, .array_list_append, "\"array_list_append\"");
                            self.addWrite(&p);
                        },
                    },
                    .linked_array_list => switch (self.rng.below(6)) {
                        0, 1 => {
                            const i = self.indexIn(size);
                            self.add(&p, .{ .linked_array_list_insert = i }, self.fmt("{{\"linked_array_list_insert\":{d}}}", .{i}));
                            self.addWrite(&p);
                        },
                        2, 3 => {
                            const i = self.indexIn(size);
                            self.add(&p, .{ .linked_array_list_remove = i }, self.fmt("{{\"linked_array_list_remove\":{d}}}", .{i}));
                        },
                        4 => {
                            const offset = self.rng.below(size + 1);
                            const new_size = self.rng.below(size - offset + 1);
                            self.add(&p, .{ .linked_array_list_slice = .{ .offset = offset, .size = new_size } }, self.fmt("{{\"linked_array_list_slice\":{{\"offset\":{d},\"size\":{d}}}}}", .{ offset, new_size }));
                        },
                        else => {
                            self.addLinkedGet(&p, self.indexIn(size));
                            self.addWrite(&p);
                        },
                    },
                    else => switch (self.rng.below(3)) {
                        0 => {
                            const key_to_remove = self.sortedKey();
                            self.add(&p, .{ .sorted_map_remove = key_to_remove.bytes }, self.fmt("{{\"sorted_map_remove\":{s}}}", .{key_to_remove.json}));
                        },
                        else => {
                            self.addSortedGet(&p, .value);
                            self.addWrite(&p);
                        },
                    },
                }
                try self.writePath(on.name, on.cursor, &p, false);
            }
            if (collection == .linked_array_list and self.depth == 1) try self.concat(index, hash_get, get_json);

            // what came of it, through the cursor as it is now, since a concat rebinds it
            const current = self.at(index);
            var read_path: PathB = .{};
            self.add(&read_path, hash_get, get_json);
            try self.beginOp();
            try self.w.print("{{\"op\":\"read_path\",\"on\":\"{s}\",\"path\":[{s}]", .{ current.name, read_path.text.items });
            const found = current.cursor.readPath(Ctx, read_path.parts.items) catch |err| {
                if (!expectable(err)) fail("the engine raised {s}, which a script can't expect", .{@errorName(err)});
                try self.w.print(",\"expect_error\":\"{s}\"}}", .{@errorName(err)});
                return;
            };
            const cursor = found orelse {
                try self.w.writeAll(",\"expect_null\":true}");
                return;
            };
            const name = self.fresh("r");
            try self.w.print(",\"as\":\"{s}\",\"expect_null\":false}}", .{name});
            try self.checkCursor(name, cursor, 0);
            for (0..3) |_| try self.readSomething(name, cursor);
        }

        /// joins another linked list onto the one under this key, or the list onto itself
        fn concat(self: *Self, index: usize, hash_get: Part, get_json: []const u8) anyerror!void {
            const on = self.at(index);
            const tag = peekTag(on.cursor, &.{});
            var other: PathB = .{};
            if (self.rng.chance(20)) {
                self.add(&other, hash_get, get_json);
            } else {
                var other_key = self.key();
                var other_get = Part{ .hash_map_get = .{ .value = other_key.hash } };
                for (0..8) |_| {
                    const existing = peekTag(on.cursor, &[_]Part{other_get});
                    if (existing == .none or existing == .linked_array_list) break;
                    other_key = self.key();
                    other_get = .{ .hash_map_get = .{ .value = other_key.hash } };
                } else return;
                self.add(&other, other_get, self.fmt("{{\"hash_map_get\":{{\"value\":{s}}}}}", .{other_key.json}));
                // something to join, unless there's already something there
                for (0..1 + self.rng.below(24)) |_| {
                    var p: PathB = .{};
                    self.addInit(&p, tag);
                    self.add(&p, other.parts.items[0], other.text.items);
                    self.addInit(&p, .linked_array_list);
                    self.add(&p, .linked_array_list_append, "\"linked_array_list_append\"");
                    self.addWrite(&p);
                    try self.writePath(on.name, on.cursor, &p, false);
                }
            }
            const found = on.cursor.readPathSlot(Ctx, other.parts.items) catch return;
            const slot = found orelse return;
            if (slot.tag != .linked_array_list) return;
            const slot_name = self.fresh("s");
            try self.beginOp();
            try self.w.print("{{\"op\":\"read_path_slot\",\"on\":\"{s}\",\"path\":[{s}],\"as\":\"{s}\"}}", .{ on.name, other.text.items, slot_name });
            var p: PathB = .{};
            self.addInit(&p, tag);
            self.add(&p, hash_get, get_json);
            self.addInit(&p, .linked_array_list);
            self.add(&p, .{ .linked_array_list_concat = .{ .list = slot } }, self.fmt("{{\"linked_array_list_concat\":{{\"list\":{{\"var\":\"{s}\"}}}}}}", .{slot_name}));
            try self.writePath(on.name, on.cursor, &p, false);

            // a concat leaves the list's old header pointing at a node newer than the
            // transaction's start, and the next init copies that header. so nothing may
            // see the old one from here on, or it's two headers for one tree: cursors kept
            // from before this, and this one's snapshot, which is why it moves the map now.
            self.first_safe_kept = self.kept.items.len;
            self.tx_concat = true;
            try self.reinit(index, tag);
        }

        /// `cursor = cursor.writePath(init)`, so that this cursor sees what's there from now on
        fn reinit(self: *Self, index: usize, tag: Tag) anyerror!void {
            const on = self.at(index);
            var p: PathB = .{};
            self.addInit(&p, tag);
            try self.beginOp();
            try self.w.print("{{\"op\":\"write_path\",\"on\":\"{s}\",\"path\":[{s}],\"as\":\"{s}\"", .{ on.name, p.text.items, on.name });
            try self.w.flush();
            if (on.cursor.writePath(Ctx, p.parts.items)) |next| {
                self.kept.items[index].cursor = next;
                try self.endOp();
            } else |err| {
                const upward = try self.noteError(err);
                try self.endOp();
                if (upward) return err;
            }
        }

        fn nested(self: *Self, index: usize) anyerror!void {
            if (self.depth >= MAX_DEPTH) return self.writeSomething(index);
            const on = self.at(index);
            var p: PathB = .{};
            var reads: std.ArrayList(Part) = .empty;
            const tag = self.walk(on.cursor, &p, &reads);
            switch (tag) {
                .hash_map, .counted_hash_map => {
                    self.maybeInit(&p, tag);
                    self.addHashGet(&p, .value);
                },
                .array_list => {
                    self.maybeInit(&p, tag);
                    self.add(&p, .array_list_append, "\"array_list_append\"");
                },
                .linked_array_list => {
                    self.maybeInit(&p, tag);
                    self.add(&p, .linked_array_list_append, "\"linked_array_list_append\"");
                },
                .sorted_map => {
                    self.maybeInit(&p, tag);
                    self.addSortedGet(&p, .value);
                },
                .none => {},
                else => return self.writeSomething(index),
            }
            self.addCtx(&p);
            try self.writePath(on.name, on.cursor, &p, self.rng.chance(20));
        }

        /// a cursor from this transaction, or now and then from an earlier one. it isn't
        /// the callback's own cursor, unless that's nested: writing a value over the
        /// moment itself would leave nothing to build on from then on.
        fn someKept(self: *Self, base: usize) ?usize {
            if (self.tx_kept_start > 0 and self.rng.chance(5)) {
                self.tx_dirty = true;
                return self.rng.below(self.tx_kept_start);
            }
            // one from before a concat can hold a header that shares a tree with a later one
            const first = @max(base + 1, self.first_safe_kept);
            if (first < self.kept.items.len) return first + self.rng.below(self.kept.items.len - first);
            return if (self.depth > 1 and base >= self.first_safe_kept) base else null;
        }

        fn writeThroughKept(self: *Self, base: usize) anyerror!void {
            const index = self.someKept(base) orelse return self.writeSomething(base);
            const name = self.at(index).name;
            const v = self.value();
            const ifEmpty = self.rng.chance(25);
            try self.beginOp();
            try self.w.print("{{\"op\":\"{s}\",\"on\":\"{s}\",\"data\":{s}", .{ if (ifEmpty) "write_if_empty" else "write", name, v.json });
            const cursor = &self.kept.items[index].cursor;
            const result = if (ifEmpty) cursor.writeIfEmpty(v.data) else cursor.write(v.data);
            if (result) |_| {
                try self.endOp();
            } else |err| {
                const upward = try self.noteError(err);
                try self.endOp();
                if (upward) return err;
            }
        }

        fn streamBytes(self: *Self, base: usize) anyerror!void {
            const index = self.someKept(base) orelse return self.writeSomething(base);
            const name = self.at(index).name;
            const a = self.randomBytes(1 + self.rng.below(30));
            const tag: ?[]const u8 = if (self.rng.chance(30)) self.randomBytes(2) else null;
            try self.beginOp();
            try self.w.print("{{\"op\":\"writer\",\"on\":\"{s}\"", .{name});
            if (tag) |t| try self.w.print(",\"format_tag\":{s}", .{self.bytesJson(t)});
            // never past the end: reading a gap before the commit is an undefined use
            const seek = self.rng.below(a.len);
            const b = self.randomBytes(1 + self.rng.below(10));
            try self.w.print(",\"steps\":[{{\"write\":{s}}},{{\"seek\":{d}}},{{\"write\":{s}}}]", .{ self.bytesJson(a), seek, self.bytesJson(b) });
            const result: anyerror!void = blk: {
                var writer = self.kept.items[index].cursor.writer(&.{}) catch |err| break :blk err;
                if (tag) |t| writer.format_tag = t[0..2].*;
                writer.interface.writeAll(a) catch |err| break :blk err;
                writer.seekTo(seek) catch |err| break :blk err;
                writer.interface.writeAll(b) catch |err| break :blk err;
                writer.finish() catch |err| break :blk err;
            };
            if (result) |_| {
                try self.endOp();
            } else |err| {
                const upward = try self.noteError(err);
                try self.endOp();
                if (upward) return err;
            }
        }

        fn freezeEverything(self: *Self) anyerror!void {
            try self.beginOp();
            try self.w.writeAll("{\"op\":\"db_freeze\"}");
            try self.db.freeze();
            self.tx_cloned = false;
            self.tx_frozen_cursor = false;
            self.tx_concat = false;
        }

        fn freezeSomething(self: *Self, base: usize) anyerror!void {
            // not a cursor, which would copy a header while unfrozen cursors go on rewriting the
            // nodes it shares: two headers for one tree, without any way to see it coming.
            // the frozen cursors here are in clone, where nothing can reach that.
            try self.freezeEverything();
            // the map has been frozen too, so it starts again from here
            const tag = peekTag(self.at(base).cursor, &.{});
            if (tag == .hash_map or tag == .counted_hash_map) try self.reinit(base, tag);
        }

        /// copies a slot from this transaction or an earlier moment under a new key,
        /// which is where aliasing and freezing come in
        fn clone(self: *Self, base: usize) anyerror!void {
            const on = self.at(base);
            const base_tag = peekTag(on.cursor, &.{});
            if (base_tag != .hash_map and base_tag != .counted_hash_map) return self.writeSomething(base);

            var from_root = self.history and self.rng.chance(50);
            if (from_root) {
                const moments = peekCount(self.db.rootCursor(), &.{});
                if (moments == 0) from_root = false;
            }
            var p: PathB = .{};
            var reads: std.ArrayList(Part) = .empty;
            if (from_root) {
                const moments = peekCount(self.db.rootCursor(), &.{});
                self.addArrayGet(&p, self.indexIn(moments));
                reads.append(self.arena, p.parts.items[0]) catch oom();
            }
            const k = self.key();
            const source_get = Part{ .hash_map_get = .{ .value = k.hash } };
            const source_json = self.fmt("{{\"hash_map_get\":{{\"value\":{s}}}}}", .{k.json});
            self.add(&p, source_get, source_json);
            reads.append(self.arena, source_get) catch oom();

            const found = if (from_root)
                self.db.rootCursor().readPathSlot(Ctx, p.parts.items) catch return self.writeSomething(base)
            else
                on.cursor.readPathSlot(Ctx, p.parts.items) catch return self.writeSomething(base);
            const slot = found orelse return self.writeSomething(base);
            switch (slot.tag) {
                .index, .kv_pair, .sorted_kv_pair => return self.writeSomething(base),
                else => {},
            }

            const slot_name = self.fresh("s");
            try self.beginOp();
            try self.w.print("{{\"op\":\"read_path_slot\",\"on\":\"{s}\",\"path\":[{s}],\"as\":\"{s}\"}}", .{ if (from_root) "root" else on.name, p.text.items, slot_name });

            var dest: PathB = .{};
            self.addInit(&dest, base_tag);
            self.addHashGet(&dest, .value);
            const before = self.kept.items.len;
            try self.writePath(on.name, on.cursor, &dest, true);
            if (self.kept.items.len == before) return; // the error was expected, so there's no cursor

            const target = before;
            try self.beginOp();
            try self.w.print("{{\"op\":\"write\",\"on\":\"{s}\",\"data\":{{\"slot\":{{\"var\":\"{s}\"}}}}", .{ self.at(target).name, slot_name });
            if (self.kept.items[target].cursor.write(.{ .slot = slot })) |_| {
                try self.endOp();
            } else |err| {
                const upward = try self.noteError(err);
                try self.endOp();
                if (upward) return err;
                return;
            }

            if (self.rng.chance(50)) {
                try self.beginOp();
                try self.w.print("{{\"op\":\"freeze\",\"on\":\"{s}\"}}", .{self.at(target).name});
                try self.kept.items[target].cursor.freeze();
                self.tx_frozen_cursor = true;
            }
            // a slot from an earlier moment holds nothing that can be rewritten in place.
            // one from this transaction might, if the clone's next init copies a header that
            // the original still uses, and a frozen cursor or a concat is what would make that so.
            if (!from_root) {
                self.tx_cloned = true;
                if (self.tx_frozen_cursor or self.tx_concat) try self.freezeEverything();
            }
            // and a change to the clone, the way the original can see or not
            try self.writeSomething(target);
        }

        fn randomReadPath(self: *Self, cursor: anytype, p: *PathB) void {
            var levels: usize = 0;
            while (levels < 5 and (levels == 0 or self.rng.chance(70))) : (levels += 1) {
                const tag = peekTag(cursor, p.parts.items);
                var step: PathB = .{};
                switch (tag) {
                    .hash_map, .counted_hash_map => self.addHashGet(&step, if (self.rng.chance(15)) .kv_pair else .value),
                    .hash_set, .counted_hash_set => self.addHashGet(&step, .key),
                    .array_list => self.addArrayGet(&step, self.indexIn(peekCount(cursor, p.parts.items) + 1)),
                    .linked_array_list => self.addLinkedGet(&step, self.indexIn(peekCount(cursor, p.parts.items) + 1)),
                    .sorted_map, .sorted_set => {
                        if (self.rng.chance(40)) {
                            const i = self.indexIn(peekCount(cursor, p.parts.items) + 1);
                            self.add(&step, .{ .sorted_map_get_index = i }, self.fmt("{{\"sorted_map_get_index\":{d}}}", .{i}));
                        } else {
                            self.addSortedGet(&step, if (self.rng.chance(15)) .kv_pair else .value);
                        }
                    },
                    else => break,
                }
                self.add(p, step.parts.items[0], step.text.items);
            }
        }

        // what --reads adds. these use their own random source and names, and nothing
        // else that's written depends on them.

        fn extraRead(self: *Self, on_name: []const u8, cursor: anytype) anyerror!void {
            const saved_rng = self.rng;
            const saved_names = self.names;
            self.rng = self.read_rng;
            self.names = self.read_names;
            defer {
                self.read_rng = self.rng;
                self.read_names = self.names;
                self.rng = saved_rng;
                self.names = saved_names;
            }

            var p: PathB = .{};
            if (self.rng.chance(70)) self.randomReadPath(cursor, &p);
            try self.beginOp();
            try self.w.print("{{\"op\":\"read_path\",\"on\":\"{s}\",\"path\":[{s}]", .{ on_name, p.text.items });
            const result = cursor.readPath(Ctx, p.parts.items) catch |err| {
                if (!expectable(err)) fail("the engine raised {s}, which a script can't expect", .{@errorName(err)});
                try self.w.print(",\"expect_error\":\"{s}\"}}", .{@errorName(err)});
                return;
            };
            const found = result orelse {
                try self.w.writeAll(",\"expect_null\":true}");
                return;
            };
            const name = self.fresh("r");
            try self.w.print(",\"as\":\"{s}\",\"expect_null\":false}}", .{name});
            try self.readThoroughly(name, found, 0);
        }

        fn readThoroughly(self: *Self, name: []const u8, cursor: RO, level: usize) anyerror!void {
            const slot = try cursor.slot();
            switch (slot.tag) {
                .bytes, .short_bytes => {
                    try self.readIntoBuffer(name, cursor, slot);
                    try self.readWithLimit(name, cursor);
                    try self.stream(name, cursor);
                },
                .none => {
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"read_bytes_into\",\"on\":\"{s}\",\"size\":0,\"expect\":\"\"}}", .{name});
                    try self.iterate(name, cursor, slot.tag, level);
                },
                .array_list, .linked_array_list, .hash_map, .hash_set, .counted_hash_map, .counted_hash_set, .sorted_map, .sorted_set => {
                    try self.iterate(name, cursor, slot.tag, level);
                    if (slot.tag == .sorted_map or slot.tag == .sorted_set) try self.rank(name, cursor);
                },
                .kv_pair, .sorted_kv_pair => if (level < 3) {
                    const pair = try cursor.readKeyValuePair();
                    const key_name = self.fresh("r");
                    const value_name = self.fresh("r");
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"read_key_value_pair\",\"on\":\"{s}\",\"key_as\":\"{s}\",\"value_as\":\"{s}\"}}", .{ name, key_name, value_name });
                    try self.readThoroughly(key_name, pair.key_cursor, level + 1);
                    try self.readThoroughly(value_name, pair.value_cursor, level + 1);
                },
                .uint, .int, .float => {
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"iterator\",\"on\":\"{s}\",\"as\":\"{s}\",\"expect_error\":\"UnexpectedTag\"}}", .{ name, self.fresh("i") });
                },
                else => {},
            }
        }

        fn writeFormatTag(self: *Self, format_tag: ?[2]u8) anyerror!void {
            if (format_tag) |tag| {
                try self.w.print(",\"expect_format_tag\":{{\"hex\":\"{s}\"}}", .{self.hex(&tag)});
            } else {
                try self.w.writeAll(",\"expect_format_tag\":null");
            }
        }

        fn readIntoBuffer(self: *Self, name: []const u8, cursor: RO, slot: Slot) anyerror!void {
            _ = slot;
            const len = (try cursor.readBytesObjectAlloc(self.arena, null)).value.len;
            const size: usize = switch (self.rng.below(3)) {
                0 => len,
                1 => len + @as(usize, @intCast(self.rng.below(9))),
                else => @as(usize, @intCast(self.rng.below(len + 1))),
            };
            const buffer = self.arena.alloc(u8, size) catch oom();
            try self.beginOp();
            try self.w.print("{{\"op\":\"read_bytes_into\",\"on\":\"{s}\",\"size\":{d}", .{ name, size });
            if (cursor.readBytesObject(buffer)) |got| {
                try self.w.print(",\"expect\":{s}", .{self.bytesJson(got.value)});
                try self.writeFormatTag(got.format_tag);
            } else |err| {
                if (err != error.StreamTooLong) fail("the engine raised {s} for a buffer", .{@errorName(err)});
                try self.w.writeAll(",\"expect_error\":\"StreamTooLong\"");
            }
            try self.endOp();
        }

        fn readWithLimit(self: *Self, name: []const u8, cursor: RO) anyerror!void {
            const len = (try cursor.readBytesObjectAlloc(self.arena, null)).value.len;
            const max_size: usize = if (self.rng.chance(50)) len else @as(usize, @intCast(self.rng.below(len + 2)));
            try self.beginOp();
            try self.w.print("{{\"op\":\"read_bytes\",\"on\":\"{s}\",\"max_size\":{d}", .{ name, max_size });
            if (cursor.readBytesObjectAlloc(self.arena, max_size)) |got| {
                try self.w.print(",\"expect\":{s}", .{self.bytesJson(got.value)});
            } else |err| {
                if (err != error.StreamTooLong) fail("the engine raised {s} with a limit", .{@errorName(err)});
                try self.w.writeAll(",\"expect_error\":\"StreamTooLong\"");
            }
            try self.endOp();
        }

        fn isPastEndOfList(iter: *RO.Iter) bool {
            const levels = iter.core.stack.slice();
            var position: u64 = 0;
            for (levels, 0..) |level, i| {
                const index: u64 = if (i == levels.len - 1) level.index - 1 else level.index;
                position = position * 16 + index;
            }
            return position >= iter.core.size;
        }

        /// whether this is a stream the port gives the same as Zig (SCRIPT-FORMAT.md, section 10)
        fn streamable(self: *Self, cursor: RO) anyerror!bool {
            const slot = try cursor.slot();
            if (slot.tag != .short_bytes) return slot.tag != .none;
            const position = cursor.slot_ptr.position orelse return false;
            if (position == 20) return true;
            var reader = self.db.core.reader();
            try reader.seekTo(position);
            var bytes: [9]u8 = undefined;
            try reader.interface.readSliceAll(&bytes);
            const current: Slot = @bitCast(std.mem.readInt(u72, &bytes, .big));
            return current.eql(slot);
        }

        fn stream(self: *Self, name: []const u8, cursor_value: RO) anyerror!void {
            if (!try self.streamable(cursor_value)) return;
            var cursor = cursor_value;
            const len = (try cursor.readBytesObjectAlloc(self.arena, null)).value.len;
            const buffer_sizes = [_]usize{ 0, 1, 7, 64 };
            const buffer_size = buffer_sizes[@intCast(self.rng.below(buffer_sizes.len))];
            const buffer = self.arena.alloc(u8, buffer_size) catch oom();

            try self.beginOp();
            try self.w.print("{{\"op\":\"read_stream\",\"on\":\"{s}\"", .{name});
            if (buffer_size > 0) try self.w.print(",\"buffer_size\":{d}", .{buffer_size});
            try self.w.writeAll(",\"steps\":[");
            var reader = try cursor.reader(buffer);
            var ended = false;
            const steps = 1 + self.rng.below(6);
            for (0..steps) |i| {
                if (i > 0) try self.w.writeAll(",");
                const size: usize = @intCast(self.rng.below(len + 3));
                const dest = self.arena.alloc(u8, size) catch oom();
                switch (self.rng.below(4)) {
                    0 => {
                        const offset = self.rng.below(len + 3);
                        try reader.seekTo(offset);
                        try self.w.print("{{\"seek\":{d}}}", .{offset});
                    },
                    1 => {
                        const got = try reader.interface.readSliceShort(dest);
                        try self.w.print("{{\"read\":{d},\"expect\":{s}}}", .{ size, self.bytesJson(dest[0..got]) });
                    },
                    2 => {
                        reader.interface.readSliceAll(dest) catch |err| {
                            if (err != error.EndOfStream) fail("the engine raised {s} in a stream", .{@errorName(err)});
                            try self.w.print("{{\"read_all\":{d}}}", .{size});
                            ended = true;
                            break;
                        };
                        try self.w.print("{{\"read_all\":{d},\"expect\":{s}}}", .{ size, self.bytesJson(dest) });
                    },
                    else => try self.w.print("{{\"position\":{d}}}", .{reader.logicalPos()}),
                }
            }
            try self.w.writeAll("]");
            if (ended) try self.w.writeAll(",\"expect_error\":\"EndOfStream\"");
            try self.endOp();
        }

        fn rank(self: *Self, name: []const u8, cursor: RO) anyerror!void {
            const k = self.sortedKey();
            const map = try DB.SortedMap(.read_only).init(cursor);
            try self.beginOp();
            try self.w.print("{{\"op\":\"rank\",\"on\":\"{s}\",\"key\":{s},\"expect\":{d}}}", .{ name, k.json, try map.rank(k.bytes) });
        }

        fn iterate(self: *Self, name: []const u8, cursor: RO, tag: Tag, level: usize) anyerror!void {
            const is_list = tag == .array_list or tag == .linked_array_list;
            const is_sorted = tag == .sorted_map or tag == .sorted_set;
            const iter_name = self.fresh("i");
            var iter: RO.Iter = undefined;
            try self.beginOp();
            try self.w.print("{{\"op\":\"iterator\",\"on\":\"{s}\",\"as\":\"{s}\"", .{ name, iter_name });
            const start = self.rng.below(100);
            if (start < 40 and (is_list or is_sorted)) {
                const count = try cursor.count();
                const index = self.indexIn(count + 3);
                try self.w.print(",\"from_index\":{d}", .{index});
                iter = switch (tag) {
                    .array_list => try RO.Iter.initArrayListFromIndex(cursor, index),
                    .linked_array_list => try RO.Iter.initLinkedArrayListFromIndex(cursor, index),
                    else => try RO.Iter.initSortedFromIndex(cursor, index),
                };
            } else if (start < 70 and is_sorted) {
                const k = self.sortedKey();
                try self.w.print(",\"from_key\":{s}", .{k.json});
                iter = try RO.Iter.initSortedFromKey(cursor, k.bytes);
            } else {
                iter = try cursor.iterator();
            }
            try self.endOp();

            // not always to the end, but past where a block ends if it can
            const steps = 1 + self.rng.below(40);
            for (0..steps) |_| {
                const next = try iter.next();
                // what the port doesn't give (SCRIPT-FORMAT.md, section 10), so a script can't ask for it
                if (next != null and tag == .array_list and isPastEndOfList(&iter)) break;
                try self.beginOp();
                const element = next orelse {
                    try self.w.print("{{\"op\":\"next\",\"on\":\"{s}\",\"expect_null\":true}}", .{iter_name});
                    break;
                };
                const element_name = self.fresh("r");
                try self.w.print("{{\"op\":\"next\",\"on\":\"{s}\",\"as\":\"{s}\",\"expect_null\":false}}", .{ iter_name, element_name });
                try self.checkCursor(element_name, element, 0);
                if (level < 3 and self.rng.chance(15)) try self.readThoroughly(element_name, element, level + 1);
            }
        }

        /// reads something and says what it should find
        fn readSomething(self: *Self, on_name: []const u8, cursor: anytype) anyerror!void {
            var p: PathB = .{};
            self.randomReadPath(cursor, &p);

            try self.beginOp();
            try self.w.print("{{\"op\":\"read_path\",\"on\":\"{s}\",\"path\":[{s}]", .{ on_name, p.text.items });
            const result = cursor.readPath(Ctx, p.parts.items) catch |err| {
                if (!expectable(err)) fail("the engine raised {s}, which a script can't expect", .{@errorName(err)});
                try self.w.print(",\"expect_error\":\"{s}\"}}", .{@errorName(err)});
                return;
            };
            const found = result orelse {
                try self.w.writeAll(",\"expect_null\":true}");
                return;
            };
            const name = self.fresh("r");
            try self.w.print(",\"as\":\"{s}\",\"expect_null\":false}}", .{name});
            try self.checkCursor(name, found, 0);
        }

        fn checkCursor(self: *Self, name: []const u8, cursor: RO, level: usize) anyerror!void {
            const slot = try cursor.slot();
            try self.beginOp();
            try self.w.print("{{\"op\":\"slot\",\"on\":\"{s}\",\"expect\":{{\"tag\":\"{s}\",\"full\":{}}}}}", .{ name, @tagName(slot.tag), slot.full });
            switch (slot.tag) {
                .uint => {
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"read_uint\",\"on\":\"{s}\",\"expect\":{d}}}", .{ name, try cursor.readUint() });
                },
                .int => {
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"read_int\",\"on\":\"{s}\",\"expect\":{d}}}", .{ name, try cursor.readInt() });
                },
                .float => {
                    const bits: u64 = @bitCast(try cursor.readFloat());
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"read_float\",\"on\":\"{s}\",\"expect\":\"{x:0>16}\"}}", .{ name, bits });
                },
                .bytes, .short_bytes => {
                    const bytes = try cursor.readBytesObjectAlloc(self.arena, null);
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"read_bytes\",\"on\":\"{s}\",\"expect\":{s},\"expect_format_tag\":", .{ name, self.bytesJson(bytes.value) });
                    if (bytes.format_tag) |tag| {
                        try self.w.print("{{\"hex\":\"{s}\"}}}}", .{self.hex(&tag)});
                    } else {
                        try self.w.writeAll("null}");
                    }
                },
                .array_list, .linked_array_list, .counted_hash_map, .counted_hash_set, .sorted_map, .sorted_set => {
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"count\",\"on\":\"{s}\",\"expect\":{d}}}", .{ name, try cursor.count() });
                },
                .kv_pair, .sorted_kv_pair => if (level == 0) {
                    const pair = try cursor.readKeyValuePair();
                    const key_name = self.fresh("r");
                    const value_name = self.fresh("r");
                    try self.beginOp();
                    try self.w.print("{{\"op\":\"read_key_value_pair\",\"on\":\"{s}\",\"key_as\":\"{s}\",\"value_as\":\"{s}\"}}", .{ name, key_name, value_name });
                    try self.checkCursor(key_name, pair.key_cursor, 1);
                    try self.checkCursor(value_name, pair.value_cursor, 1);
                },
                else => {},
            }
        }

        /// the ops of a callback
        fn body(self: *Self, base: usize) anyerror!void {
            const n = 1 + self.rng.below(if (self.depth == 1) 12 else 4);
            for (0..n) |_| {
                if (self.reads and self.read_rng.chance(25)) {
                    const on = self.at(base);
                    try self.extraRead(on.name, on.cursor);
                }
                const r = self.rng.below(100);
                if (r < 36) {
                    try self.writeSomething(base);
                } else if (r < 48) {
                    const on = self.at(base);
                    try self.readSomething(on.name, on.cursor);
                } else if (r < 56) {
                    try self.writeThroughKept(base);
                } else if (r < 64) {
                    try self.nested(base);
                } else if (r < 72) {
                    try self.clone(base);
                } else if (r < 77) {
                    try self.streamBytes(base);
                } else if (r < 82) {
                    try self.freezeSomething(base);
                } else if (r < 86) {
                    if (self.history) try self.readSomething("root", self.db.rootCursor()) else try self.writeSomething(base);
                } else if (r < 95) {
                    try self.burst(base);
                } else if (r < 97) {
                    // a nested write at the top level, which is always refused
                    var p: PathB = .{};
                    self.add(&p, .array_list_append, "\"array_list_append\"");
                    try self.writePath("root", self.db.rootCursor(), &p, false);
                } else if (r < 98 and !self.tx_dirty) {
                    try self.beginOp();
                    try self.w.writeAll("{\"op\":\"fail\"}");
                    return error.ScriptAbort;
                } else {
                    try self.writeSomething(base);
                }
            }
        }

        // the top level

        fn noteCommit(self: *Self, before: u64) anyerror!void {
            const size = try self.db.committedSize();
            // it only goes down when the root header is set back, which isn't a commit
            if (size > before) {
                var root: [9]u8 = undefined;
                @memcpy(&root, self.buffer.written()[@intCast(size - TRAILER_SIZE)..][0..9]);
                self.commits.append(self.arena, .{ .size = size, .root = root }) catch oom();
                if (self.tx_dirty) self.first_lost_commit = self.commits.items.len - 1;
            }
        }

        fn moment(self: *Self) anyerror!void {
            const root = self.db.rootCursor();
            const last = root.readPathSlot(Ctx, &.{.{ .array_list_get = -1 }}) catch null;
            const last_name = self.fresh("s");
            try self.beginOp();
            try self.w.print("{{\"op\":\"read_path_slot\",\"on\":\"root\",\"path\":[{{\"array_list_get\":-1}}],\"as\":\"{s}\"}}", .{last_name});

            var p: PathB = .{};
            self.add(&p, .array_list_init, "\"array_list_init\"");
            self.add(&p, .array_list_append, "\"array_list_append\"");
            self.add(&p, .{ .write = .{ .slot = last } }, self.fmt("{{\"write\":{{\"slot\":{{\"var\":\"{s}\"}}}}}}", .{last_name}));
            self.add(&p, .{ .hash_map_init = .{} }, "{\"hash_map_init\":{}}");
            if (self.rng.chance(85)) {
                self.addCtx(&p);
            } else {
                self.addHashGet(&p, .value);
                self.addWrite(&p);
            }
            try self.topLevelWrite(&p);
        }

        fn topLevelWrite(self: *Self, p: *PathB) anyerror!void {
            const kept_before = self.kept.items.len;
            self.tx_kept_start = kept_before;
            self.top_failed = false;
            try self.writePath("root", self.db.rootCursor(), p, false);
            if (self.top_failed) self.kept.shrinkRetainingCapacity(kept_before);
        }

        fn mapRootBatch(self: *Self) anyerror!void {
            const kept_before = self.kept.items.len;
            self.tx_kept_start = kept_before;
            const name = self.fresh("c");
            try self.beginOp();
            try self.w.print("{{\"op\":\"run_context\",\"ctx\":{{\"as\":\"{s}\",\"ops\":[", .{name});
            const result = self.db.runContext(Ctx{ .g = self, .name = name });
            try self.w.writeAll("]}");
            if (result) |_| {} else |err| {
                if (!expectable(err)) fail("the engine raised {s}, which a script can't expect", .{@errorName(err)});
                try self.w.print(",\"expect_error\":\"{s}\"", .{@errorName(err)});
                self.kept.shrinkRetainingCapacity(kept_before);
            }
            try self.endOp();
        }

        fn undo(self: *Self) anyerror!void {
            const moments = peekCount(self.db.rootCursor(), &.{});
            if (moments == 0) return self.moment();
            const i = self.indexIn(moments);
            const slot = self.db.rootCursor().readPathSlot(Ctx, &.{.{ .array_list_get = i }}) catch null;
            const name = self.fresh("s");
            try self.beginOp();
            try self.w.print("{{\"op\":\"read_path_slot\",\"on\":\"root\",\"path\":[{{\"array_list_get\":{d}}}],\"as\":\"{s}\"}}", .{ i, name });
            var p: PathB = .{};
            self.add(&p, .array_list_append, "\"array_list_append\"");
            self.add(&p, .{ .write = .{ .slot = slot } }, self.fmt("{{\"write\":{{\"slot\":{{\"var\":\"{s}\"}}}}}}", .{name}));
            try self.topLevelWrite(&p);
        }

        fn closeDatabase(self: *Self) anyerror!void {
            try self.beginOp();
            try self.w.writeAll("{\"op\":\"close\"}");
            self.kept.clearRetainingCapacity();
            self.tx_kept_start = 0;
        }

        fn reopen(self: *Self, read_only: bool) anyerror!void {
            try self.beginOp();
            if (read_only) {
                try self.w.writeAll("{\"op\":\"reopen\",\"read_only\":true}");
            } else {
                try self.w.writeAll("{\"op\":\"reopen\"}");
            }
            self.db = try DB.init(self.io, .{ .buffer = self.buffer });
        }

        fn rawAppend(self: *Self) anyerror!void {
            const bytes = self.randomBytes(1 + self.rng.below(60));
            try self.beginOp();
            try self.w.print("{{\"op\":\"raw_append\",\"bytes\":{s}}}", .{self.bytesJson(bytes)});
            try self.buffer.writer.writeAll(bytes);
        }

        fn rawWriteHeader(self: *Self, bytes: []const u8) anyerror!void {
            try self.beginOp();
            try self.w.print("{{\"op\":\"raw_write\",\"offset\":20,\"bytes\":{s}}}", .{self.bytesJson(bytes)});
            @memcpy(self.buffer.written()[20..][0..bytes.len], bytes);
        }

        fn topLevelOp(self: *Self) anyerror!void {
            if (self.reads and self.read_rng.chance(40)) try self.extraRead("root", self.db.rootCursor());
            const before = try self.db.committedSize();
            self.tx_dirty = false;
            self.tx_cloned = false;
            self.tx_frozen_cursor = false;
            self.tx_concat = false;
            self.first_safe_kept = 0;
            defer self.noteCommit(before) catch {};

            const r = self.rng.below(100);
            if (self.history) {
                if (self.read_only_allowed and self.rng.chance(10)) {
                    try self.closeDatabase();
                    try self.reopen(true);
                    try self.readSomething("root", self.db.rootCursor());
                    // the memory kind used here can't be read-only, so what a write does is
                    // written down without doing it. run and check.sh hold it to that.
                    try self.beginOp();
                    try self.w.writeAll("{\"op\":\"write_path\",\"on\":\"root\",\"path\":[\"array_list_init\",\"array_list_append\",{\"write\":{\"uint\":1}}],\"expect_error\":\"WriteFailed\"}");
                    try self.closeDatabase();
                    try self.reopen(false);
                } else if (r < 70) {
                    try self.moment();
                } else if (r < 84) {
                    try self.readSomething("root", self.db.rootCursor());
                } else if (r < 88) {
                    try self.undo();
                } else if (r < 91) {
                    try self.closeDatabase();
                    try self.reopen(false);
                } else if (r < 94) {
                    try self.closeDatabase();
                    try self.rawAppend();
                    try self.reopen(false);
                    if (self.rng.chance(50)) {
                        var p: PathB = .{};
                        self.add(&p, .array_list_init, "\"array_list_init\"");
                        try self.writePath("root", self.db.rootCursor(), &p, false);
                    }
                } else if (r < 96 and self.commits.items.len >= self.first_lost_commit + 2) {
                    // a commit lost before the root header pointed at it
                    const keep = self.first_lost_commit + self.rng.below(self.commits.items.len - 1 - self.first_lost_commit);
                    const commit = self.commits.items[@intCast(keep)];
                    var header: [17]u8 = undefined;
                    @memcpy(header[0..9], &commit.root);
                    std.mem.writeInt(u64, header[9..17], commit.size, .big);
                    try self.closeDatabase();
                    try self.rawWriteHeader(&header);
                    try self.reopen(false);
                    self.commits.shrinkRetainingCapacity(@intCast(keep + 1));
                } else if (r < 98) {
                    // a torn cached root slot, which is never read
                    const garbage: [9]u8 = @splat(0xff);
                    try self.closeDatabase();
                    try self.rawWriteHeader(&garbage);
                    try self.reopen(false);
                } else {
                    try self.moment();
                }
            } else {
                if (r < 40) {
                    try self.mapRootBatch();
                } else if (r < 70) {
                    var p: PathB = .{};
                    var reads: std.ArrayList(Part) = .empty;
                    const root = self.db.rootCursor();
                    const tag = self.walk(root, &p, &reads);
                    self.finish(root, &p, reads.items, tag);
                    try self.topLevelWrite(&p);
                } else if (r < 90) {
                    try self.readSomething("root", self.db.rootCursor());
                } else {
                    try self.closeDatabase();
                    try self.reopen(false);
                }
            }
        }

        fn generate(self: *Self, ops: u64, compact: bool) anyerror!void {
            for (0..ops) |_| {
                try self.topLevelOp();
            }
            if (compact) {
                try self.beginOp();
                try self.w.writeAll("{\"op\":\"compact\",\"into\":\"compacted\",\"file_id\":\"00000000000000cc\",\"offset_map\":\"memory\"}");
            }
        }
    };
}

fn run(comptime HashInt: type, io: Io, arena: Allocator, gpa: Allocator, seed: u64, ops: u64, reads: bool, compact: bool, out_path: []const u8) !void {
    const G = Gen(HashInt);
    const hash_size = @bitSizeOf(HashInt) / 8;

    var rng: Rng = .{ .state = seed };
    const file_id = rng.next();
    const history = rng.below(100) < 80;
    const read_only_allowed = rng.below(100) < 20;
    // a third need only array lists and hash maps, and a third add linked lists to those
    const linked_allowed = seed % 3 != 0;
    const sorted_allowed = seed % 3 == 2;

    const out = try Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out.close(io);
    var out_buffer: [64 * 1024]u8 = undefined;
    var out_writer = out.writerStreaming(io, &out_buffer);
    const w = &out_writer.interface;

    try w.print("{{\n  \"format\": \"{s}\",\n  \"description\": \"Generated by gen from seed {d}{s}.\",\n  \"hash_size\": {d},\n  \"hash_id\": {s},\n  \"file_id\": \"{x:0>16}\",\n  \"ops\": [", .{
        SCRIPT_FORMAT,
        seed,
        if (reads and compact) ", with reads and a compaction" else if (reads) ", with reads" else if (compact) ", with a compaction" else "",
        hash_size,
        if (hash_size == 20) "\"sha1\"" else "null",
        file_id,
    });

    var buffer = Io.Writer.Allocating.init(gpa);
    defer buffer.deinit();

    var g: G = .{ .io = io, .arena = arena, .rng = rng, .w = w, .buffer = &buffer, .read_only_allowed = read_only_allowed, .linked_allowed = linked_allowed, .sorted_allowed = sorted_allowed, .history = history, .reads = reads, .read_rng = .{ .state = seed ^ 0x5245414453 } };
    g.db = try G.DB.init(io, .{ .buffer = &buffer, .file_id = file_id });

    try g.generate(ops, compact);

    try w.writeAll("\n  ]\n}\n");
    try w.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) {
        std.debug.print("usage: gen <seed> <out.script> [--ops <top-level ops>] [--reads] [--compact]\n", .{});
        std.process.exit(2);
    }
    const seed = std.fmt.parseInt(u64, args[1], 10) catch fail("the seed must be a number", .{});
    var ops: u64 = 15;
    var reads = false;
    var compact = false;
    var arg_index: usize = 3;
    while (arg_index < args.len) : (arg_index += 1) {
        if (std.mem.eql(u8, args[arg_index], "--reads")) {
            reads = true;
        } else if (std.mem.eql(u8, args[arg_index], "--compact")) {
            compact = true;
        } else if (std.mem.eql(u8, args[arg_index], "--ops") and arg_index + 1 < args.len) {
            arg_index += 1;
            ops = std.fmt.parseInt(u64, args[arg_index], 10) catch fail("--ops must be a number", .{});
        } else fail("the options are --ops, --reads and --compact", .{});
    }

    // a few scripts use a short hash, written in hex
    if (seed % 8 == 7) {
        try run(u64, io, arena, init.gpa, seed, ops, reads, compact, args[2]);
    } else {
        try run(u160, io, arena, init.gpa, seed, ops, reads, compact, args[2]);
    }
}
