//! run <script> <out.db> [--kind buffered_file|file|memory]
//!
//! Executes a conformance script (see SCRIPT-FORMAT.md) against the Zig
//! implementation and writes the database to <out.db> and the sidecar to
//! <out.db>.sidecar.json. Every script op maps to one call of xitdb's API, and
//! the only state added here is the table of names that ops refer to.
//!
//! Exits with 0 on success, 1 when the script fails (an unexpected error, an
//! expectation not met, or a malformed script), and 2 on a usage error. Output
//! files must not be used after a nonzero exit.

const std = @import("std");
const xitdb = @import("xitdb");

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SIDECAR_SUFFIX = ".sidecar.json";
const SCRIPT_FORMAT = "xitdb-script/1";
const SIDECAR_FORMAT = "xitdb-sidecar/1";

// where the runner is in the script, for messages only

var loc_buf: [4096]u8 = undefined;
var loc_len: usize = 0;

fn pushLoc(comptime fmt: []const u8, args: anytype) usize {
    const saved = loc_len;
    const written = std.fmt.bufPrint(loc_buf[loc_len..], fmt, args) catch return saved;
    loc_len += written.len;
    return saved;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("script failure at {s}: " ++ fmt ++ "\n", .{loc_buf[0..loc_len]} ++ args);
    std.process.exit(1);
}

// an error has usually travelled out of some callbacks by the time it fails the
// script, so this is where the current one started

var error_loc_buf: [4096]u8 = undefined;
var error_loc_len: usize = 0;

fn noteErrorLoc() void {
    if (error_loc_len == 0) {
        @memcpy(error_loc_buf[0..loc_len], loc_buf[0..loc_len]);
        error_loc_len = loc_len;
    }
}

// reading JSON. everything is checked, so a typo in a hand-written script can't
// silently change what it does. numbers are kept as strings by the parser, so
// integers are exact over their whole range.

fn asObject(v: Json, what: []const u8) ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => die("{s} must be an object", .{what}),
    };
}

fn asArray(v: Json, what: []const u8) []const Json {
    return switch (v) {
        .array => |a| a.items,
        else => die("{s} must be an array", .{what}),
    };
}

fn asString(v: Json, what: []const u8) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => die("{s} must be a string", .{what}),
    };
}

fn asBool(v: Json, what: []const u8) bool {
    return switch (v) {
        .bool => |b| b,
        else => die("{s} must be true or false", .{what}),
    };
}

fn asInt(comptime T: type, v: Json, what: []const u8) T {
    const s = switch (v) {
        .number_string => |s| s,
        else => die("{s} must be an integer", .{what}),
    };
    return std.fmt.parseInt(T, s, 10) catch die("{s}: {s} is not a valid {s}", .{ what, s, @typeName(T) });
}

fn required(obj: ObjectMap, key: []const u8, what: []const u8) Json {
    return obj.get(key) orelse die("{s} needs a \"{s}\" field", .{ what, key });
}

fn checkKeys(obj: ObjectMap, allowed: []const []const u8, what: []const u8) void {
    outer: for (obj.keys()) |key| {
        for (allowed) |name| {
            if (std.mem.eql(u8, key, name)) continue :outer;
        }
        die("unknown field \"{s}\" in {s}", .{ key, what });
    }
}

fn onlyKey(obj: ObjectMap, what: []const u8) struct { key: []const u8, value: Json } {
    if (obj.count() != 1) die("{s} must have exactly one field", .{what});
    return .{ .key = obj.keys()[0], .value = obj.values()[0] };
}

fn isKey(key: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, key, name);
}

fn parseHex(arena: Allocator, s: []const u8, what: []const u8) []const u8 {
    if (s.len % 2 != 0) die("{s}: odd number of hex digits", .{what});
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => die("{s}: hex digits must be 0-9 and lowercase a-f", .{what}),
        }
    }
    const out = arena.alloc(u8, s.len / 2) catch die("out of memory", .{});
    _ = std.fmt.hexToBytes(out, s) catch die("{s}: invalid hex", .{what});
    return out;
}

/// a 64-bit value written as 16 hex digits, most significant first: file IDs and float bit patterns
fn parseHex64(arena: Allocator, v: Json, what: []const u8) u64 {
    const s = asString(v, what);
    if (s.len != 16) die("{s}: must be exactly 16 hex digits", .{what});
    const bytes = parseHex(arena, s, what);
    return std.mem.readInt(u64, bytes[0..8], .big);
}

/// a byte string: a JSON string (its UTF-8 encoding) or {"hex": "..."}
fn parseBytes(arena: Allocator, v: Json, what: []const u8) []const u8 {
    switch (v) {
        .string => |s| return s,
        .object => |o| {
            checkKeys(o, &.{"hex"}, what);
            return parseHex(arena, asString(required(o, "hex", what), what), what);
        },
        else => die("{s} must be a string or {{\"hex\": ...}}", .{what}),
    }
}

fn parseFixedBytes(comptime N: usize, arena: Allocator, v: Json, what: []const u8) [N]u8 {
    const bytes = parseBytes(arena, v, what);
    if (bytes.len != N) die("{s} must be exactly {d} bytes, got {d}", .{ what, N, bytes.len });
    return bytes[0..N].*;
}

fn hasExpectedError(op: ObjectMap) ?[]const u8 {
    const v = op.get("expect_error") orelse return null;
    return asString(v, "expect_error");
}

const OpKind = enum {
    write_path,
    write,
    write_if_empty,
    writer,
    freeze,
    db_freeze,
    run_context,
    fail,
    read_path,
    read_path_slot,
    slot,
    read_only,
    read_key_value_pair,
    read_uint,
    read_int,
    read_float,
    read_bytes,
    count,
};

const SidecarEntry = struct {
    committed_size: u64,
    commit_id: ?u64,
};

const Options = struct {
    io: Io,
    arena: Allocator,
    gpa: Allocator,
    ops: []const Json,
    file_id: u64,
    hash_id: ?xitdb.HashId,
    out_path: []const u8,
};

fn Runner(comptime kind: xitdb.DatabaseKind, comptime HashInt: type) type {
    return struct {
        const Self = @This();
        const DB = xitdb.Database(kind, HashInt);
        const RW = DB.Cursor(.read_write);
        const RO = DB.Cursor(.read_only);
        const Slot = xitdb.Slot;
        const Part = DB.PathPart(Ctx);
        const Data = DB.WriteableData;
        const HASH_SIZE = @bitSizeOf(HashInt) / 8;

        // the trailer's size, and where the commit ID is inside it
        const TRAILER_SIZE = 25;
        const TRAILER_COMMIT_ID_OFFSET = 9;

        const Binding = union(enum) {
            rw: RW,
            ro: RO,
            slot: ?Slot,
            // what `read_path` found nothing for
            null_cursor,
        };

        /// the callback of a `ctx` path part. the callback's cursor is bound to
        /// `name` while it runs, and whatever `name` holds at the end is what the
        /// callback leaves in `*cursor` (see "Callbacks" in SCRIPT-FORMAT.md).
        pub const Ctx = struct {
            runner: *Self,
            name: []const u8,
            ops: []const Json,

            pub fn run(self: Ctx, cursor: *RW) anyerror!void {
                const r = self.runner;
                const saved_loc = pushLoc("/ctx:{s}", .{self.name});
                defer loc_len = saved_loc;

                if (r.active.contains(self.name)) die("callback name \"{s}\" is already in use by an enclosing callback", .{self.name});
                r.active.put(r.arena, self.name, {}) catch die("out of memory", .{});
                defer _ = r.active.remove(self.name);

                r.bind(self.name, .{ .rw = cursor.* });

                r.depth += 1;
                defer r.depth -= 1;
                try r.execOps(self.ops);

                switch (r.env.get(self.name).?) {
                    .rw => |c| cursor.* = c,
                    else => die("callback name \"{s}\" must hold a read-write cursor when the callback ends", .{self.name}),
                }
            }
        };

        io: Io,
        db: *DB,
        arena: Allocator,
        env: std.StringHashMapUnmanaged(Binding) = .empty,
        active: std.StringHashMapUnmanaged(void) = .empty,
        depth: usize = 0,
        // the storage behind a `root` reference by pointer
        root_cursor: RW = undefined,

        // names

        fn bind(self: *Self, name: []const u8, binding: Binding) void {
            if (isKey(name, "root")) die("\"root\" can't be bound", .{});
            for (name, 0..) |c, i| {
                switch (c) {
                    'a'...'z', 'A'...'Z', '_' => {},
                    '0'...'9' => if (i == 0) die("names can't start with a digit: \"{s}\"", .{name}),
                    else => die("names can only have ASCII letters, digits and underscores: \"{s}\"", .{name}),
                }
            }
            if (name.len == 0) die("names can't be empty", .{});
            self.env.put(self.arena, name, binding) catch die("out of memory", .{});
        }

        fn lookup(self: *Self, name: []const u8) Binding {
            if (isKey(name, "root")) return .{ .rw = self.db.rootCursor() };
            return self.env.get(name) orelse die("\"{s}\" is not bound", .{name});
        }

        fn cursorName(op: ObjectMap) []const u8 {
            return asString(required(op, "on", "this op"), "on");
        }

        /// the cursor called `name` as a value, for methods that don't change it
        fn rwValue(self: *Self, name: []const u8) RW {
            return switch (self.lookup(name)) {
                .rw => |c| c,
                .ro => die("\"{s}\" is a read-only cursor", .{name}),
                .slot => die("\"{s}\" is a slot, not a cursor", .{name}),
                .null_cursor => die("\"{s}\" is a null cursor", .{name}),
            };
        }

        /// the cursor called `name` by pointer, for methods that update it
        fn rwPointer(self: *Self, name: []const u8) *RW {
            if (isKey(name, "root")) {
                self.root_cursor = self.db.rootCursor();
                return &self.root_cursor;
            }
            const binding = self.env.getPtr(name) orelse die("\"{s}\" is not bound", .{name});
            return switch (binding.*) {
                .rw => |*c| c,
                .ro => die("\"{s}\" is a read-only cursor", .{name}),
                .slot => die("\"{s}\" is a slot, not a cursor", .{name}),
                .null_cursor => die("\"{s}\" is a null cursor", .{name}),
            };
        }

        /// the cursor called `name`, read-write or read-only
        fn anyCursor(self: *Self, name: []const u8) Binding {
            const binding = self.lookup(name);
            return switch (binding) {
                .rw, .ro => binding,
                .slot => die("\"{s}\" is a slot, not a cursor", .{name}),
                .null_cursor => die("\"{s}\" is a null cursor", .{name}),
            };
        }

        fn wrap(cursor: anytype) Binding {
            return if (@TypeOf(cursor) == RW) .{ .rw = cursor } else .{ .ro = cursor };
        }

        // values

        fn parseHash(self: *Self, v: Json) HashInt {
            const only = onlyKey(asObject(v, "a hash"), "a hash");
            var bytes: [HASH_SIZE]u8 = undefined;
            if (isKey(only.key, "hex")) {
                const s = asString(only.value, "a hash");
                if (s.len != HASH_SIZE * 2) die("a hex hash must be exactly {d} digits in a database with this hash size, got {d}", .{ HASH_SIZE * 2, s.len });
                @memcpy(&bytes, parseHex(self.arena, s, "a hash"));
            } else if (isKey(only.key, "sha1")) {
                if (HASH_SIZE != 20) die("a sha1 hash needs a hash size of 20, this database has {d}", .{HASH_SIZE});
                var digest: [20]u8 = undefined;
                std.crypto.hash.Sha1.hash(parseBytes(self.arena, only.value, "the input to sha1"), &digest, .{});
                @memcpy(bytes[0..20], &digest);
            } else die("a hash must be {{\"hex\": ...}} or {{\"sha1\": ...}}", .{});
            return std.mem.readInt(HashInt, &bytes, .big);
        }

        fn parseSlot(self: *Self, v: Json) ?Slot {
            switch (v) {
                .null => return null,
                .object => |o| {
                    if (o.get("var")) |name_value| {
                        checkKeys(o, &.{"var"}, "a slot variable");
                        const name = asString(name_value, "var");
                        return switch (self.lookup(name)) {
                            .slot => |s| s,
                            else => die("\"{s}\" is not a slot", .{name}),
                        };
                    }
                    checkKeys(o, &.{ "tag", "value", "full" }, "a literal slot");
                    return .{
                        .tag = parseTag(asString(required(o, "tag", "a literal slot"), "tag")),
                        .value = if (o.get("value")) |value| asInt(u64, value, "value") else 0,
                        .full = if (o.get("full")) |full| asBool(full, "full") else false,
                    };
                },
                else => die("a slot must be null, {{\"var\": ...}} or a literal slot", .{}),
            }
        }

        fn parseTag(name: []const u8) xitdb.Tag {
            return std.meta.stringToEnum(xitdb.Tag, name) orelse die("\"{s}\" is not a tag", .{name});
        }

        fn parseData(self: *Self, v: Json) Data {
            const only = onlyKey(asObject(v, "write data"), "write data");
            if (isKey(only.key, "slot")) return .{ .slot = self.parseSlot(only.value) };
            if (isKey(only.key, "uint")) return .{ .uint = asInt(u64, only.value, "uint") };
            if (isKey(only.key, "int")) return .{ .int = asInt(i64, only.value, "int") };
            if (isKey(only.key, "float")) return .{ .float = @bitCast(parseHex64(self.arena, only.value, "float")) };
            if (isKey(only.key, "bytes")) return .{ .bytes = parseBytes(self.arena, only.value, "bytes") };
            if (isKey(only.key, "bytes_object")) {
                const o = asObject(only.value, "bytes_object");
                checkKeys(o, &.{ "value", "format_tag" }, "bytes_object");
                return .{ .bytes_object = .{
                    .value = parseBytes(self.arena, required(o, "value", "bytes_object"), "value"),
                    .format_tag = if (o.get("format_tag")) |tag| parseFixedBytes(2, self.arena, tag, "format_tag") else null,
                } };
            }
            die("unknown write data \"{s}\"", .{only.key});
        }

        fn parseIndex(v: Json, what: []const u8) i65 {
            // i65 in Zig, but the script format only goes as far as i64
            return asInt(i64, v, what);
        }

        fn parsePath(self: *Self, v: Json) []const Part {
            const items = asArray(v, "path");
            const path = self.arena.alloc(Part, items.len) catch die("out of memory", .{});
            for (items, path, 0..) |item, *part, i| {
                const saved_loc = pushLoc("/path[{d}]", .{i});
                defer loc_len = saved_loc;
                part.* = self.parsePart(item);
            }
            return path;
        }

        fn parsePart(self: *Self, v: Json) Part {
            if (v == .string) {
                const s = v.string;
                if (isKey(s, "array_list_init")) return .array_list_init;
                if (isKey(s, "array_list_append")) return .array_list_append;
                if (isKey(s, "linked_array_list_init")) return .linked_array_list_init;
                if (isKey(s, "linked_array_list_append")) return .linked_array_list_append;
                die("\"{s}\" is not a path part without a payload", .{s});
            }

            const only = onlyKey(asObject(v, "a path part"), "a path part");
            const key = only.key;
            const value = only.value;

            if (isKey(key, "array_list_get")) return .{ .array_list_get = parseIndex(value, key) };
            if (isKey(key, "array_list_slice")) {
                const o = asObject(value, key);
                checkKeys(o, &.{"size"}, key);
                return .{ .array_list_slice = .{ .size = asInt(u64, required(o, "size", key), "size") } };
            }
            if (isKey(key, "linked_array_list_get")) return .{ .linked_array_list_get = parseIndex(value, key) };
            if (isKey(key, "linked_array_list_slice")) {
                const o = asObject(value, key);
                checkKeys(o, &.{ "offset", "size" }, key);
                return .{ .linked_array_list_slice = .{
                    .offset = asInt(u64, required(o, "offset", key), "offset"),
                    .size = asInt(u64, required(o, "size", key), "size"),
                } };
            }
            if (isKey(key, "linked_array_list_concat")) {
                const o = asObject(value, key);
                checkKeys(o, &.{"list"}, key);
                const list = self.parseSlot(required(o, "list", key)) orelse die("the list of {s} can't be null", .{key});
                return .{ .linked_array_list_concat = .{ .list = list } };
            }
            if (isKey(key, "linked_array_list_insert")) return .{ .linked_array_list_insert = parseIndex(value, key) };
            if (isKey(key, "linked_array_list_remove")) return .{ .linked_array_list_remove = parseIndex(value, key) };
            if (isKey(key, "hash_map_init")) {
                const o = asObject(value, key);
                checkKeys(o, &.{ "counted", "set" }, key);
                return .{ .hash_map_init = .{
                    .counted = if (o.get("counted")) |c| asBool(c, "counted") else false,
                    .set = if (o.get("set")) |s| asBool(s, "set") else false,
                } };
            }
            if (isKey(key, "hash_map_get")) {
                const target = onlyKey(asObject(value, key), key);
                const hash = self.parseHash(target.value);
                if (isKey(target.key, "kv_pair")) return .{ .hash_map_get = .{ .kv_pair = hash } };
                if (isKey(target.key, "key")) return .{ .hash_map_get = .{ .key = hash } };
                if (isKey(target.key, "value")) return .{ .hash_map_get = .{ .value = hash } };
                die("{s} must target kv_pair, key or value", .{key});
            }
            if (isKey(key, "hash_map_remove")) return .{ .hash_map_remove = self.parseHash(value) };
            if (isKey(key, "sorted_map_init")) {
                const o = asObject(value, key);
                checkKeys(o, &.{"set"}, key);
                return .{ .sorted_map_init = .{ .set = if (o.get("set")) |s| asBool(s, "set") else false } };
            }
            if (isKey(key, "sorted_map_get")) {
                const target = onlyKey(asObject(value, key), key);
                const bytes = parseBytes(self.arena, target.value, "a sorted key");
                if (isKey(target.key, "kv_pair")) return .{ .sorted_map_get = .{ .kv_pair = bytes } };
                if (isKey(target.key, "key")) return .{ .sorted_map_get = .{ .key = bytes } };
                if (isKey(target.key, "value")) return .{ .sorted_map_get = .{ .value = bytes } };
                die("{s} must target kv_pair, key or value", .{key});
            }
            if (isKey(key, "sorted_map_get_index")) return .{ .sorted_map_get_index = parseIndex(value, key) };
            if (isKey(key, "sorted_map_remove")) return .{ .sorted_map_remove = parseBytes(self.arena, value, key) };
            if (isKey(key, "write")) return .{ .write = self.parseData(value) };
            if (isKey(key, "ctx")) return .{ .ctx = self.parseCtx(value) };
            die("\"{s}\" is not a path part", .{key});
        }

        fn parseCtx(self: *Self, v: Json) Ctx {
            const o = asObject(v, "a callback");
            checkKeys(o, &.{ "as", "ops" }, "a callback");
            return .{
                .runner = self,
                .name = asString(required(o, "as", "a callback"), "as"),
                .ops = asArray(required(o, "ops", "a callback"), "ops"),
            };
        }

        // expectations

        fn checkNull(op: ObjectMap, is_null: bool) void {
            const v = op.get("expect_null") orelse return;
            const want = asBool(v, "expect_null");
            if (want != is_null) die("expected a {s} result, got a {s} one", .{ if (want) "null" else "non-null", if (is_null) "null" else "non-null" });
        }

        fn checkSlot(op: ObjectMap, slot: ?Slot) void {
            const v = op.get("expect") orelse return;
            const want = asObject(v, "expect");
            checkKeys(want, &.{ "tag", "value", "full" }, "expect");
            const s = slot orelse die("expected a slot, got null", .{});
            if (want.get("tag")) |tag| {
                const name = asString(tag, "tag");
                if (s.tag != parseTag(name)) die("expected tag {s}, got {s}", .{ name, @tagName(s.tag) });
            }
            if (want.get("value")) |value| {
                const n = asInt(u64, value, "value");
                if (s.value != n) die("expected slot value {d}, got {d}", .{ n, s.value });
            }
            if (want.get("full")) |full| {
                const b = asBool(full, "full");
                if (s.full != b) die("expected full={}, got full={}", .{ b, s.full });
            }
        }

        // ops

        fn execOps(self: *Self, ops: []const Json) anyerror!void {
            for (ops, 0..) |op, i| {
                const saved_loc = pushLoc("/ops[{d}]", .{i});
                defer loc_len = saved_loc;
                try self.execOp(op);
            }
        }

        /// runs one op. with `expect_error` the op must fail with that error, which
        /// ends here; without it, an error is returned to whoever is running the
        /// ops, the way `try` would in a Zig callback.
        fn execOp(self: *Self, op_value: Json) anyerror!void {
            const op = asObject(op_value, "an op");
            const expected = hasExpectedError(op);
            const result = self.dispatch(op);
            if (result) |_| {} else |_| noteErrorLoc();
            const want = expected orelse return result;
            if (result) |_| {
                die("expected error {s}, but the op succeeded", .{want});
            } else |err| {
                if (!std.mem.eql(u8, @errorName(err), want)) die("expected error {s}, got {s}, which started at {s}", .{ want, @errorName(err), error_loc_buf[0..error_loc_len] });
                error_loc_len = 0;
            }
        }

        fn dispatch(self: *Self, op: ObjectMap) anyerror!void {
            const name = asString(required(op, "op", "an op"), "op");
            const kind_of_op = std.meta.stringToEnum(OpKind, name) orelse die("\"{s}\" is not an op", .{name});

            switch (kind_of_op) {
                .write_path => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "path", "as" }, name);
                    const cursor = self.rwValue(cursorName(op));
                    const path = self.parsePath(required(op, "path", name));
                    const next = try cursor.writePath(Ctx, path);
                    if (op.get("as")) |as| self.bind(asString(as, "as"), .{ .rw = next });
                },
                .write => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "data" }, name);
                    const data = self.parseData(required(op, "data", name));
                    try self.rwPointer(cursorName(op)).write(data);
                },
                .write_if_empty => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "data" }, name);
                    const data = self.parseData(required(op, "data", name));
                    try self.rwPointer(cursorName(op)).writeIfEmpty(data);
                },
                .writer => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "format_tag", "steps" }, name);
                    const steps = asArray(required(op, "steps", name), "steps");
                    const format_tag: ?[2]u8 = if (op.get("format_tag")) |tag| parseFixedBytes(2, self.arena, tag, "format_tag") else null;
                    const cursor = self.rwPointer(cursorName(op));
                    var writer = try cursor.writer(&.{});
                    writer.format_tag = format_tag;
                    for (steps) |step_value| {
                        const step = onlyKey(asObject(step_value, "a writer step"), "a writer step");
                        if (isKey(step.key, "write")) {
                            try writer.interface.writeAll(parseBytes(self.arena, step.value, "write"));
                        } else if (isKey(step.key, "seek")) {
                            try writer.seekTo(asInt(u64, step.value, "seek"));
                        } else die("a writer step must be \"write\" or \"seek\"", .{});
                    }
                    try writer.finish();
                },
                .freeze => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on" }, name);
                    try self.rwPointer(cursorName(op)).freeze();
                },
                .db_freeze => {
                    checkKeys(op, &.{ "op", "note", "expect_error" }, name);
                    try self.db.freeze();
                },
                .run_context => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "ctx" }, name);
                    try self.db.runContext(self.parseCtx(required(op, "ctx", name)));
                },
                .fail => {
                    checkKeys(op, &.{ "op", "note" }, name);
                    if (self.depth == 0) die("fail can only be used in a callback", .{});
                    return error.ScriptAbort;
                },
                .read_path => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "path", "as", "expect_null" }, name);
                    const path = self.parsePath(required(op, "path", name));
                    const result = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readPath(Ctx, path),
                        else => unreachable,
                    };
                    checkNull(op, result == null);
                    if (op.get("as")) |as| self.bind(asString(as, "as"), if (result) |c| .{ .ro = c } else .null_cursor);
                },
                .read_path_slot => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "path", "as", "expect_null", "expect" }, name);
                    const path = self.parsePath(required(op, "path", name));
                    const result = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readPathSlot(Ctx, path),
                        else => unreachable,
                    };
                    checkNull(op, result == null);
                    checkSlot(op, result);
                    if (op.get("as")) |as| self.bind(asString(as, "as"), .{ .slot = result });
                },
                .slot => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "as", "expect" }, name);
                    const result = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.slot(),
                        else => unreachable,
                    };
                    checkSlot(op, result);
                    if (op.get("as")) |as| self.bind(asString(as, "as"), .{ .slot = result });
                },
                .read_only => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "as" }, name);
                    const result = self.rwValue(cursorName(op)).readOnly();
                    self.bind(asString(required(op, "as", name), "as"), .{ .ro = result });
                },
                .read_key_value_pair => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "key_as", "value_as", "expect_hash" }, name);
                    switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| {
                            const pair = try c.readKeyValuePair();
                            if (op.get("expect_hash")) |hash| {
                                const want = self.parseHash(hash);
                                if (pair.hash != want) die("expected hash {x}, got {x}", .{ want, pair.hash });
                            }
                            if (op.get("key_as")) |as| self.bind(asString(as, "key_as"), wrap(pair.key_cursor));
                            if (op.get("value_as")) |as| self.bind(asString(as, "value_as"), wrap(pair.value_cursor));
                        },
                        else => unreachable,
                    }
                },
                .read_uint => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "expect" }, name);
                    const got = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readUint(),
                        else => unreachable,
                    };
                    if (op.get("expect")) |v| {
                        const want = asInt(u64, v, "expect");
                        if (got != want) die("expected uint {d}, got {d}", .{ want, got });
                    }
                },
                .read_int => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "expect" }, name);
                    const got = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readInt(),
                        else => unreachable,
                    };
                    if (op.get("expect")) |v| {
                        const want = asInt(i64, v, "expect");
                        if (got != want) die("expected int {d}, got {d}", .{ want, got });
                    }
                },
                .read_float => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "expect" }, name);
                    const got = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readFloat(),
                        else => unreachable,
                    };
                    if (op.get("expect")) |v| {
                        const want = parseHex64(self.arena, v, "expect");
                        const got_bits: u64 = @bitCast(got);
                        if (got_bits != want) die("expected float bits {x:0>16}, got {x:0>16}", .{ want, got_bits });
                    }
                },
                .read_bytes => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "expect", "expect_format_tag" }, name);
                    const got = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readBytesObjectAlloc(self.arena, null),
                        else => unreachable,
                    };
                    if (op.get("expect")) |v| {
                        const want = parseBytes(self.arena, v, "expect");
                        if (!std.mem.eql(u8, got.value, want)) die("expected bytes \"{s}\", got \"{s}\"", .{ want, got.value });
                    }
                    if (op.get("expect_format_tag")) |v| {
                        const want: ?[2]u8 = if (v == .null) null else parseFixedBytes(2, self.arena, v, "expect_format_tag");
                        if (want == null and got.format_tag != null) die("expected no format tag, got one", .{});
                        if (want != null and (got.format_tag == null or !std.mem.eql(u8, &want.?, &got.format_tag.?))) die("expected a different format tag", .{});
                    }
                },
                .count => {
                    checkKeys(op, &.{ "op", "note", "expect_error", "on", "expect" }, name);
                    const got = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.count(),
                        else => unreachable,
                    };
                    if (op.get("expect")) |v| {
                        const want = asInt(u64, v, "expect");
                        if (got != want) die("expected count {d}, got {d}", .{ want, got });
                    }
                },
            }
        }

        // the top level. each op gets one sidecar entry.

        fn readCommitId(self: *Self, committed_size: u64) !u64 {
            var reader = self.db.core.reader();
            try reader.seekTo(committed_size - TRAILER_SIZE + TRAILER_COMMIT_ID_OFFSET);
            var bytes: [8]u8 = undefined;
            try reader.interface.readSliceAll(&bytes);
            return std.mem.readInt(u64, &bytes, .big);
        }

        fn execTopLevel(self: *Self, ops: []const Json, entries: []SidecarEntry) !void {
            for (ops, entries, 0..) |op, *entry, i| {
                const saved_loc = pushLoc("ops[{d}]", .{i});
                defer loc_len = saved_loc;

                const before = try self.db.committedSize();
                self.execOp(op) catch |err| die("unexpected error {s}, which started at {s}", .{ @errorName(err), error_loc_buf[0..error_loc_len] });
                const after = try self.db.committedSize();

                // a transaction either committed or was rolled back, so nothing
                // can be left past the committed bytes between top-level ops
                const length = try self.db.core.length();
                if (length != after) die("{d} bytes are left past the committed size {d}", .{ length - after, after });

                entry.* = .{
                    .committed_size = after,
                    .commit_id = if (after != before) try self.readCommitId(after) else null,
                };
            }
        }

        fn runScript(opts: Options) !void {
            const io = opts.io;
            const out = try Io.Dir.cwd().createFile(io, opts.out_path, .{ .read = true, .truncate = true });
            defer out.close(io);

            var buffer = Io.Writer.Allocating.init(opts.gpa);
            defer buffer.deinit();

            const init_opts: xitdb.InitOpts(kind) = switch (kind) {
                .memory => .{ .buffer = &buffer, .hash_id = opts.hash_id, .file_id = opts.file_id },
                .file => .{ .file = out, .fsync = false, .hash_id = opts.hash_id, .file_id = opts.file_id },
                .buffered_file => .{ .file = out, .buffer = &buffer, .fsync = false, .hash_id = opts.hash_id, .file_id = opts.file_id },
            };
            var db = try DB.init(io, init_opts);
            const initial_size = try db.committedSize();

            var self: Self = .{ .io = io, .db = &db, .arena = opts.arena };
            const entries = try opts.arena.alloc(SidecarEntry, opts.ops.len);
            try self.execTopLevel(opts.ops, entries);

            try db.core.flush();
            if (kind == .memory) try out.writeStreamingAll(io, buffer.written());

            const file_size = try db.core.length();
            try writeSidecar(opts, initial_size, file_size, entries);
        }

        fn writeSidecar(opts: Options, initial_size: u64, file_size: u64, entries: []const SidecarEntry) !void {
            var text = Io.Writer.Allocating.init(opts.gpa);
            defer text.deinit();
            const w = &text.writer;

            try w.print("{{\n  \"format\": \"{s}\",\n  \"file_id\": \"{x:0>16}\",\n  \"initial_size\": {d},\n  \"file_size\": {d},\n  \"ops\": [", .{
                SIDECAR_FORMAT,
                opts.file_id,
                initial_size,
                file_size,
            });
            for (entries, 0..) |entry, i| {
                try w.writeAll(if (i == 0) "\n" else ",\n");
                if (entry.commit_id) |id| {
                    try w.print("    {{\"committed_size\": {d}, \"commit_id\": \"{x:0>16}\"}}", .{ entry.committed_size, id });
                } else {
                    try w.print("    {{\"committed_size\": {d}, \"commit_id\": null}}", .{entry.committed_size});
                }
            }
            try w.writeAll(if (entries.len == 0) "]\n}\n" else "\n  ]\n}\n");

            const path = try std.mem.concat(opts.arena, u8, &.{ opts.out_path, SIDECAR_SUFFIX });
            const file = try Io.Dir.cwd().createFile(opts.io, path, .{ .truncate = true });
            defer file.close(opts.io);
            try file.writeStreamingAll(opts.io, text.written());
        }
    };
}

fn usage() noreturn {
    std.debug.print("usage: run <script> <out.db> [--kind buffered_file|file|memory]\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 and args.len != 5) usage();
    var kind: xitdb.DatabaseKind = .buffered_file;
    if (args.len == 5) {
        if (!std.mem.eql(u8, args[3], "--kind")) usage();
        kind = std.meta.stringToEnum(xitdb.DatabaseKind, args[4]) orelse usage();
    }

    const text = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited);
    const parsed = std.json.parseFromSliceLeaky(Json, arena, text, .{
        .parse_numbers = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| die("not valid JSON: {s}", .{@errorName(err)});

    const script = asObject(parsed, "the script");
    checkKeys(script, &.{ "format", "description", "hash_size", "hash_id", "file_id", "ops" }, "the script");

    const format = asString(required(script, "format", "the script"), "format");
    if (!std.mem.eql(u8, format, SCRIPT_FORMAT)) die("unknown format \"{s}\"", .{format});

    const hash_id_value = required(script, "hash_id", "the script");
    const hash_id: ?xitdb.HashId = if (hash_id_value == .null) null else blk: {
        const bytes = parseFixedBytes(4, arena, hash_id_value, "hash_id");
        break :blk xitdb.HashId.fromBytes(&bytes);
    };
    const file_id = parseHex64(arena, required(script, "file_id", "the script"), "file_id");
    const ops = asArray(required(script, "ops", "the script"), "ops");
    const hash_size = asInt(u16, required(script, "hash_size", "the script"), "hash_size");

    switch (kind) {
        inline else => |k| {
            const common: Options = .{
                .io = io,
                .arena = arena,
                .gpa = init.gpa,
                .ops = ops,
                .file_id = file_id,
                .hash_id = hash_id,
                .out_path = args[2],
            };
            switch (hash_size) {
                8 => try Runner(k, u64).runScript(common),
                20 => try Runner(k, u160).runScript(common),
                32 => try Runner(k, u256).runScript(common),
                64 => try Runner(k, u512).runScript(common),
                else => die("hash_size must be 8, 20, 32 or 64, got {d}", .{hash_size}),
            }
        },
    }
}
