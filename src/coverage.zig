//! coverage <script>...
//!
//! Fails unless the scripts between them use every op, path part, form of value and
//! error name in SCRIPT-FORMAT.md. It also fails on anything they use that isn't on
//! its list, so the list can't fall behind when the format grows.
//!
//! This looks at what a script says, including parts that are never reached, and not
//! at what ran. The gate gives it the hand-written scripts only, so that a generated
//! one can't hide something nobody wrote a script for.

const std = @import("std");

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Io = std.Io;

const WANT = [_][]const u8{
    // ops
    "op:write_path",
    "op:write",
    "op:write_if_empty",
    "op:writer",
    "op:freeze",
    "op:db_freeze",
    "op:run_context",
    "op:fail",
    "op:read_path",
    "op:read_path_slot",
    "op:slot",
    "op:read_only",
    "op:read_key_value_pair",
    "op:read_uint",
    "op:read_int",
    "op:read_float",
    "op:read_bytes",
    "op:read_bytes_into",
    "op:read_stream",
    "op:count",
    "op:iterator",
    "op:next",
    "op:rank",
    "op:close",
    "op:reopen",
    "op:raw_append",
    "op:raw_write",
    "op:create_database",
    "op:use",
    "op:compact",
    "op:replica_state",
    "op:replication_start",
    "op:committed_size",
    "op:read_committed",
    "op:apply_replicated",
    // path parts
    "part:array_list_init",
    "part:array_list_get",
    "part:array_list_append",
    "part:array_list_slice",
    "part:linked_array_list_init",
    "part:linked_array_list_get",
    "part:linked_array_list_append",
    "part:linked_array_list_slice",
    "part:linked_array_list_concat",
    "part:linked_array_list_insert",
    "part:linked_array_list_remove",
    "part:hash_map_init",
    "part:hash_map_get",
    "part:hash_map_remove",
    "part:sorted_map_init",
    "part:sorted_map_get",
    "part:sorted_map_get_index",
    "part:sorted_map_remove",
    "part:write",
    "part:ctx",
    // what they can say
    "hash_map_get:kv_pair",
    "hash_map_get:key",
    "hash_map_get:value",
    "sorted_map_get:kv_pair",
    "sorted_map_get:key",
    "sorted_map_get:value",
    "hash_map_init:plain",
    "hash_map_init:counted",
    "hash_map_init:set",
    "hash_map_init:counted_set",
    "hash_map_init:explicit_false",
    "sorted_map_init:plain",
    "sorted_map_init:set",
    "sorted_map_init:explicit_false",
    // write data
    "data:slot",
    "data:uint",
    "data:int",
    "data:float",
    "data:bytes",
    "data:bytes_object",
    "bytes_object:with_tag",
    "bytes_object:no_tag",
    // slots
    "slot:null",
    "slot:var",
    "slot:literal",
    "literal:none",
    "literal:short_bytes",
    "literal:uint",
    "literal:int",
    "literal:float",
    "literal:full_true",
    "literal:full_false",
    // the ends of the integer ranges
    "uint:max",
    "int:max",
    "int:min",
    // the forms of bytes, where they appear
    "bytes:text",
    "bytes:hex",
    "bytes:hex_empty",
    "bytes_object.value:text",
    "bytes_object.value:hex",
    "format_tag:text",
    "format_tag:hex",
    "writer_step.write:text",
    "writer_step.write:hex",
    "sorted_key:text",
    "sorted_key:hex",
    "sorted_map_remove:text",
    "sorted_map_remove:hex",
    "raw:text",
    "raw:hex",
    "hash:hex",
    "hash:sha1_text",
    "hash:sha1_hex",
    // writer
    "writer_step:write",
    "writer_step:seek",
    "writer:format_tag",
    // reads
    "read_bytes:max_size",
    "iterator:plain",
    "iterator:from_index",
    "iterator:from_index_negative",
    "iterator:from_key",
    "from_key:text",
    "from_key:hex",
    "from_key:hex_empty",
    "rank_key:text",
    "rank_key:hex",
    "rank_key:hex_empty",
    "stream:buffer_size",
    "stream_step:read",
    "stream_step:read_all",
    "stream_step:seek",
    "stream_step:position",
    "stream_expect:text",
    "stream_expect:hex",
    // several databases
    "create_database:hash_id",
    "compact:new",
    "compact:file_id",
    "compact:hash_id",
    "compact:memory",
    "compact:disk",
    // replication
    "number:integer",
    "number:var",
    "read_committed:expect_same",
    "apply_replicated:short_by",
    // the top of a script
    "hash_id:text",
    "hash_id:hex",
    "hash_id:null",
    "hash_size:8",
    "hash_size:20",
    "hash_size:32",
    "hash_size:64",
    // expectations
    "expect_tag:none",
    "expect_tag:array_list",
    "expect_tag:linked_array_list",
    "expect_tag:hash_map",
    "expect_tag:kv_pair",
    "expect_tag:bytes",
    "expect_tag:short_bytes",
    "expect_tag:uint",
    "expect_tag:int",
    "expect_tag:float",
    "expect_tag:hash_set",
    "expect_tag:counted_hash_map",
    "expect_tag:counted_hash_set",
    "expect_tag:sorted_map",
    "expect_tag:sorted_set",
    "expect_tag:sorted_kv_pair",
    "expect:slot_value",
    "expect:slot_full",
    "expect_null:true",
    "expect_null:false",
    "expect_format_tag:null",
    "expect_format_tag:tag",
    "expect_hash",
    // what binds a name
    "bind:as",
    "bind:key_as",
    "bind:value_as",
    // reopening
    "reopen:read_only",
    "reopen:hash_size",
    // error names
    "error:KeyNotFound",
    "error:UnexpectedTag",
    "error:WriteNotAllowed",
    "error:CursorNotWriteable",
    "error:ExpectedTxStart",
    "error:NestedTopLevelWrite",
    "error:PathPartMustBeAtEnd",
    "error:ScriptAbort",
    "error:WriteFailed",
    "error:InvalidDatabase",
    "error:InvalidVersion",
    "error:InvalidHashSize",
    "error:TruncatedDatabase",
    "error:EndOfStream",
    "error:StreamTooLong",
    "error:TargetNotEmpty",
    "error:InvalidRange",
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("coverage: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Walker = struct {
    arena: std.mem.Allocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    fn note(self: *Walker, comptime prefix: []const u8, name: []const u8) void {
        const key = std.mem.concat(self.arena, u8, &.{ prefix, name }) catch fail("out of memory", .{});
        self.seen.put(self.arena, key, {}) catch fail("out of memory", .{});
    }

    fn bytes(self: *Walker, comptime where: []const u8, v: Json) void {
        switch (v) {
            .string => self.note(where ++ ":", "text"),
            .object => |o| {
                const hex = o.get("hex").?.string;
                self.note(where ++ ":", "hex");
                if (hex.len == 0) self.note(where ++ ":", "hex_empty");
            },
            else => fail("bytes are neither text nor hex", .{}),
        }
    }

    fn hash(self: *Walker, v: Json) void {
        const o = v.object;
        if (o.get("hex") != null) {
            self.note("hash:", "hex");
        } else {
            switch (o.get("sha1").?) {
                .string => self.note("hash:", "sha1_text"),
                else => self.note("hash:", "sha1_hex"),
            }
        }
    }

    fn slot(self: *Walker, v: Json) void {
        switch (v) {
            .null => self.note("slot:", "null"),
            .object => |o| {
                if (o.get("var") != null) {
                    self.note("slot:", "var");
                    return;
                }
                self.note("slot:", "literal");
                self.note("literal:", o.get("tag").?.string);
                if (o.get("full")) |full| self.note("literal:", if (full.bool) "full_true" else "full_false");
            },
            else => fail("a slot is neither null nor an object", .{}),
        }
    }

    fn data(self: *Walker, v: Json) void {
        const o = v.object;
        const name = o.keys()[0];
        const value = o.values()[0];
        self.note("data:", name);
        if (std.mem.eql(u8, name, "slot")) self.slot(value);
        if (std.mem.eql(u8, name, "bytes")) self.bytes("bytes", value);
        if (std.mem.eql(u8, name, "uint") and std.mem.eql(u8, value.number_string, "18446744073709551615")) self.note("uint:", "max");
        if (std.mem.eql(u8, name, "int") and std.mem.eql(u8, value.number_string, "9223372036854775807")) self.note("int:", "max");
        if (std.mem.eql(u8, name, "int") and std.mem.eql(u8, value.number_string, "-9223372036854775808")) self.note("int:", "min");
        if (std.mem.eql(u8, name, "bytes_object")) {
            self.bytes("bytes_object.value", value.object.get("value").?);
            if (value.object.get("format_tag")) |tag| {
                self.note("bytes_object:", "with_tag");
                self.bytes("format_tag", tag);
            } else {
                self.note("bytes_object:", "no_tag");
            }
        }
    }

    fn path(self: *Walker, items: []const Json) void {
        for (items) |part| {
            if (part == .string) {
                self.note("part:", part.string);
                continue;
            }
            const name = part.object.keys()[0];
            const value = part.object.values()[0];
            self.note("part:", name);
            if (std.mem.eql(u8, name, "write")) self.data(value);
            if (std.mem.eql(u8, name, "ctx")) self.ops(value.object.get("ops").?.array.items);
            if (std.mem.eql(u8, name, "linked_array_list_concat")) self.slot(value.object.get("list").?);
            if (std.mem.eql(u8, name, "hash_map_remove")) self.hash(value);
            if (std.mem.eql(u8, name, "sorted_map_remove")) self.bytes("sorted_map_remove", value);
            if (std.mem.eql(u8, name, "hash_map_get")) {
                self.note("hash_map_get:", value.object.keys()[0]);
                self.hash(value.object.values()[0]);
            }
            if (std.mem.eql(u8, name, "sorted_map_get")) {
                self.note("sorted_map_get:", value.object.keys()[0]);
                self.bytes("sorted_key", value.object.values()[0]);
            }
            if (std.mem.eql(u8, name, "hash_map_init")) {
                const counted = if (value.object.get("counted")) |c| c.bool else false;
                const set = if (value.object.get("set")) |c| c.bool else false;
                self.note("hash_map_init:", if (counted and set) "counted_set" else if (counted) "counted" else if (set) "set" else "plain");
                if (value.object.get("set")) |c| {
                    if (!c.bool) self.note("hash_map_init:", "explicit_false");
                }
            }
            if (std.mem.eql(u8, name, "sorted_map_init")) {
                const set = if (value.object.get("set")) |c| c.bool else false;
                self.note("sorted_map_init:", if (set) "set" else "plain");
                if (value.object.get("set")) |c| {
                    if (!c.bool) self.note("sorted_map_init:", "explicit_false");
                }
            }
        }
    }

    fn ops(self: *Walker, items: []const Json) void {
        for (items) |item| {
            const op = item.object;
            const name = op.get("op").?.string;
            self.note("op:", name);
            if (op.get("expect_error")) |err| self.note("error:", err.string);
            if (op.get("path")) |p| self.path(p.array.items);
            if (op.get("data")) |d| self.data(d);
            if (op.get("ctx")) |c| self.ops(c.object.get("ops").?.array.items);
            if (op.get("as") != null) self.note("bind:", "as");
            if (op.get("key_as") != null) self.note("bind:", "key_as");
            if (op.get("value_as") != null) self.note("bind:", "value_as");
            if (op.get("expect_null")) |v| self.note("expect_null:", if (v.bool) "true" else "false");
            if (op.get("expect_hash")) |h| {
                self.note("expect_hash", "");
                self.hash(h);
            }
            if (op.get("expect_format_tag")) |v| {
                self.note("expect_format_tag:", if (v == .null) "null" else "tag");
                if (v != .null) self.bytes("format_tag", v);
            }
            if (op.get("expect")) |v| {
                if (v == .object and (std.mem.eql(u8, name, "slot") or std.mem.eql(u8, name, "read_path_slot"))) {
                    if (v.object.get("tag")) |tag| self.note("expect_tag:", tag.string);
                    if (v.object.get("value") != null) self.note("expect:", "slot_value");
                    if (v.object.get("full") != null) self.note("expect:", "slot_full");
                }
            }
            if (std.mem.eql(u8, name, "writer")) {
                if (op.get("format_tag")) |tag| {
                    self.note("writer:", "format_tag");
                    self.bytes("format_tag", tag);
                }
                for (op.get("steps").?.array.items) |step| {
                    const step_name = step.object.keys()[0];
                    self.note("writer_step:", step_name);
                    if (std.mem.eql(u8, step_name, "write")) self.bytes("writer_step.write", step.object.values()[0]);
                }
            }
            if (std.mem.eql(u8, name, "reopen")) {
                if (op.get("read_only")) |v| {
                    if (v.bool) self.note("reopen:", "read_only");
                }
                if (op.get("hash_size") != null) self.note("reopen:", "hash_size");
            }
            if (std.mem.eql(u8, name, "raw_append") or std.mem.eql(u8, name, "raw_write")) {
                self.bytes("raw", op.get("bytes").?);
            }
            if (op.get("max_size") != null) self.note("read_bytes:", "max_size");
            if (std.mem.eql(u8, name, "create_database") and op.get("hash_id") != null) self.note("create_database:", "hash_id");
            if (std.mem.eql(u8, name, "compact")) {
                self.note("compact:", op.get("offset_map").?.string);
                if (op.get("file_id") != null) {
                    self.note("compact:", "new");
                    self.note("compact:", "file_id");
                }
                if (op.get("hash_id") != null) self.note("compact:", "hash_id");
            }
            if (std.mem.eql(u8, name, "read_committed")) {
                self.number(op.get("start").?);
                self.number(op.get("end").?);
                if (op.get("expect_same") != null) self.note("read_committed:", "expect_same");
            }
            if (std.mem.eql(u8, name, "apply_replicated")) {
                self.number(op.get("start").?);
                if (op.get("short_by") != null) self.note("apply_replicated:", "short_by");
            }
            if (std.mem.eql(u8, name, "iterator")) {
                if (op.get("from_index")) |v| {
                    self.note("iterator:", if (v.number_string[0] == '-') "from_index_negative" else "from_index");
                } else if (op.get("from_key")) |v| {
                    self.note("iterator:", "from_key");
                    self.bytes("from_key", v);
                } else {
                    self.note("iterator:", "plain");
                }
            }
            if (std.mem.eql(u8, name, "rank")) self.bytes("rank_key", op.get("key").?);
            if (std.mem.eql(u8, name, "read_stream")) {
                if (op.get("buffer_size") != null) self.note("stream:", "buffer_size");
                for (op.get("steps").?.array.items) |step| {
                    for (step.object.keys()) |key| {
                        if (!std.mem.eql(u8, key, "expect")) self.note("stream_step:", key);
                    }
                    if (step.object.get("expect")) |v| self.bytes("stream_expect", v);
                }
            }
        }
    }

    fn number(self: *Walker, v: Json) void {
        self.note("number:", if (v == .number_string) "integer" else "var");
    }

    fn script(self: *Walker, doc: ObjectMap) void {
        self.note("hash_size:", doc.get("hash_size").?.number_string);
        switch (doc.get("hash_id").?) {
            .null => self.note("hash_id:", "null"),
            .string => self.note("hash_id:", "text"),
            else => self.note("hash_id:", "hex"),
        }
        self.ops(doc.get("ops").?.array.items);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: coverage <script>...\n", .{});
        std.process.exit(2);
    }

    var walker: Walker = .{ .arena = arena };
    for (args[1..]) |path| {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        const doc = try std.json.parseFromSliceLeaky(Json, arena, text, .{ .parse_numbers = false });
        walker.script(doc.object);
    }

    var problems: usize = 0;
    for (WANT) |want| {
        if (!walker.seen.contains(want)) {
            std.debug.print("coverage: nothing uses {s}\n", .{want});
            problems += 1;
        }
    }
    // the other way around, so that this list keeps up with the format
    var seen = walker.seen.keyIterator();
    while (seen.next()) |key| {
        var found = false;
        for (WANT) |want| {
            if (std.mem.eql(u8, want, key.*)) found = true;
        }
        if (!found) {
            std.debug.print("coverage: {s} is used, but it isn't on this tool's list\n", .{key.*});
            problems += 1;
        }
    }
    if (problems > 0) std.process.exit(1);

    var stdout_buffer: [256]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout.interface.print("coverage: {d} scripts use all of the {d} things on the list\n", .{ args.len - 1, WANT.len });
    try stdout.interface.flush();
}
