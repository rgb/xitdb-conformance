//! run <script> <out.db> [--kind buffered_file|file|memory] [--allow-port-differences] [--note-port-changes]
//!
//! Executes a conformance script (see SCRIPT-FORMAT.md) against the Zig
//! implementation and writes the database to <out.db> and the sidecar to
//! <out.db>.sidecar.json. Any other database a script makes goes next to it, as
//! <out>.<name>.db. Every script op maps to one call of xitdb's API, and the only
//! state added here is the table of names that ops refer to, and which database
//! is the current one.
//!
//! The whole script is validated before the database is created, so a script
//! this runner accepts is well-formed everywhere, including in ops that are
//! never reached. Everything that uses a script can rely on that.
//!
//! Exits with 0 on success, 1 when the script fails (it isn't valid, an error
//! nothing handled, or an expectation not met), and 2 on a usage error. Output
//! files must not be used after a nonzero exit.
//!
//! The Swift port deliberately differs from Zig in a few reads (SCRIPT-FORMAT.md,
//! section 10), so a valid script can't use them, and this refuses to run one that
//! does. --allow-port-differences lets through the scripts in tests/port-differs,
//! which exist to show what each implementation does there.
//!
//! --note-port-changes prints a line beginning `change` for each place a script
//! relies on something the port will change after its parity gate, which is what
//! impact.sh makes PORT-IMPACT.md from. It doesn't change what's run.

const std = @import("std");
const xitdb = @import("xitdb");

const Json = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const SIDECAR_SUFFIX = ".sidecar.json";
const SCRIPT_FORMAT = "xitdb-script/1";
const SIDECAR_FORMAT = "xitdb-sidecar/1";

/// seeking further isn't a limit of the engine. it keeps a script runnable on
/// every storage kind, and away from overflowing the writer's position.
const MAX_SEEK = 1 << 24;

/// callbacks nest this deep at most. each one is 5 levels of JSON, and Swift's JSON
/// parsers stop at 512 levels, while this runner's stack lasts for about 300 callbacks.
const MAX_CALLBACK_DEPTH = 64;

/// what expect_error can name. the engine has other errors, but reaching them takes
/// an undefined use or a corrupt file, so a script has no business expecting them.
const ERROR_NAMES = [_][]const u8{
    "KeyNotFound",
    "UnexpectedTag",
    "WriteNotAllowed",
    "CursorNotWriteable",
    "ExpectedTxStart",
    "NestedTopLevelWrite",
    "PathPartMustBeAtEnd",
    "ScriptAbort",
    "WriteFailed",
    "InvalidDatabase",
    "InvalidVersion",
    "InvalidHashSize",
    "TruncatedDatabase",
    "EndOfStream",
    "StreamTooLong",
    "TargetNotEmpty",
    "InvalidRange",
};

/// only a read the port corrects can raise this, so only --allow-port-differences lets a script name it
const PORT_DIFFERENCE_ERROR_NAMES = [_][]const u8{"ExpectedSlotPosition"};

// where the runner is in the script, for messages only

var loc_buf: [4096]u8 = undefined;
var loc_len: usize = 0;

fn pushLoc(comptime fmt: []const u8, args: anytype) usize {
    const saved = loc_len;
    const written = std.fmt.bufPrint(loc_buf[loc_len..], fmt, args) catch return saved;
    loc_len += written.len;
    return saved;
}

fn pushOpLoc(i: usize) usize {
    return if (loc_len == 0) pushLoc("ops[{d}]", .{i}) else pushLoc("/ops[{d}]", .{i});
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
    const value = std.fmt.parseInt(T, s, 10) catch die("{s}: {s} is not a valid {s}", .{ what, s, @typeName(T) });
    if (value == 0 and s[0] == '-') die("{s}: -0 is not a valid {s}", .{ what, @typeName(T) });
    return value;
}

fn required(obj: ObjectMap, key: []const u8, what: []const u8) Json {
    return obj.get(key) orelse die("{s} needs a field called {s}", .{ what, key });
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
        .string => |s| {
            // JSONSerialization in Swift silently drops one of these from the start of a string
            if (std.mem.find(u8, s, "\xef\xbb\xbf") != null) die("{s}: U+FEFF can't be in a string, so write these bytes as hex", .{what});
            return s;
        },
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

/// ASCII letters, digits and underscores, not starting with a digit
fn checkName(name: []const u8, what: []const u8) void {
    if (name.len == 0) die("{s} can't be empty", .{what});
    for (name, 0..) |c, i| {
        switch (c) {
            'a'...'z', 'A'...'Z', '_' => {},
            '0'...'9' => if (i == 0) die("{s} can't start with a digit: \"{s}\"", .{ what, name }),
            else => die("{s} can only have ASCII letters, digits and underscores: \"{s}\"", .{ what, name }),
        }
    }
}

/// a name that something can be bound to, which is any name but "root"
fn checkBindable(name: []const u8, what: []const u8) void {
    checkName(name, what);
    if (isKey(name, "root")) die("\"root\" can't be bound", .{});
}

fn checkErrorName(name: []const u8, op_name: []const u8, allow_port_differences: bool) void {
    if (allow_port_differences) {
        for (PORT_DIFFERENCE_ERROR_NAMES) |known| {
            if (isKey(name, known)) return;
        }
    }
    // reading a gap before the commit raises it on one storage kind and not on the others,
    // and reading a slot set to nothing into a buffer raises it where the port doesn't.
    // only a stream can reach it in a way that means the same everywhere.
    // and applying bytes at 0 that are too short to be a database raises it everywhere,
    // there and from then on when asking that database where its committed bytes end
    const end_of_stream_means_the_same = isKey(op_name, "read_stream") or isKey(op_name, "apply_replicated") or isKey(op_name, "committed_size") or isKey(op_name, "replica_state");
    if (isKey(name, "EndOfStream") and !end_of_stream_means_the_same and !allow_port_differences) {
        die("expect_error can't name EndOfStream on {s}", .{op_name});
    }
    for (ERROR_NAMES) |known| {
        if (isKey(name, known)) return;
    }
    die("expect_error can't name \"{s}\"", .{name});
}

/// an optional field that binds a name
fn checkBindableField(op: ObjectMap, field: []const u8) void {
    const v = op.get(field) orelse return;
    checkBindable(asString(v, field), field);
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
    read_bytes_into,
    read_stream,
    count,
    iterator,
    next,
    rank,
    close,
    reopen,
    raw_append,
    raw_write,
    create_database,
    use,
    compact,
    replica_state,
    replication_start,
    committed_size,
    read_committed,
    apply_replicated,
};

fn opFields(kind: OpKind) []const []const u8 {
    return switch (kind) {
        .write_path => &.{ "op", "note", "expect_error", "on", "path", "as" },
        .write, .write_if_empty => &.{ "op", "note", "expect_error", "on", "data" },
        .writer => &.{ "op", "note", "expect_error", "on", "format_tag", "steps" },
        .freeze => &.{ "op", "note", "expect_error", "on" },
        .db_freeze => &.{ "op", "note", "expect_error" },
        .run_context => &.{ "op", "note", "expect_error", "ctx" },
        .fail => &.{ "op", "note" },
        .read_path => &.{ "op", "note", "expect_error", "on", "path", "as", "expect_null" },
        .read_path_slot => &.{ "op", "note", "expect_error", "on", "path", "as", "expect_null", "expect" },
        .slot => &.{ "op", "note", "expect_error", "on", "as", "expect" },
        .read_only => &.{ "op", "note", "expect_error", "on", "as" },
        .read_key_value_pair => &.{ "op", "note", "expect_error", "on", "key_as", "value_as", "expect_hash" },
        .read_uint, .read_int, .read_float, .count => &.{ "op", "note", "expect_error", "on", "expect" },
        .read_bytes => &.{ "op", "note", "expect_error", "on", "max_size", "expect", "expect_format_tag" },
        .read_bytes_into => &.{ "op", "note", "expect_error", "on", "size", "expect", "expect_format_tag" },
        .read_stream => &.{ "op", "note", "expect_error", "on", "buffer_size", "steps" },
        .iterator => &.{ "op", "note", "expect_error", "on", "from_index", "from_key", "as" },
        .next => &.{ "op", "note", "expect_error", "on", "as", "expect_null" },
        .rank => &.{ "op", "note", "expect_error", "on", "key", "expect" },
        .close => &.{ "op", "note" },
        .reopen => &.{ "op", "note", "expect_error", "read_only", "hash_size" },
        .raw_append => &.{ "op", "note", "bytes" },
        .raw_write => &.{ "op", "note", "offset", "bytes" },
        .create_database => &.{ "op", "note", "name", "file_id", "hash_id" },
        .use => &.{ "op", "note", "name" },
        .compact => &.{ "op", "note", "expect_error", "into", "file_id", "hash_id", "offset_map" },
        .replica_state => &.{ "op", "note", "expect_error", "as" },
        .replication_start => &.{ "op", "note", "expect_error", "state", "as", "expect" },
        .committed_size => &.{ "op", "note", "expect_error", "as", "expect" },
        .read_committed => &.{ "op", "note", "expect_error", "start", "end", "as", "expect_same" },
        .apply_replicated => &.{ "op", "note", "expect_error", "start", "bytes", "short_by" },
    };
}

const SidecarEntry = struct {
    // null while the database is closed
    committed_size: ?u64,
    commit_id: ?u64,
    // which database they're about, if it isn't the script's own
    db: ?[]const u8 = null,
};

/// a commit's trailer that's in a database's file. it can have come from another database
/// through replication, so it says which file ID its checksum goes by.
const Trailer = struct {
    position: u64,
    commit_id: u64,
    file_id: u64,
};

fn checkHashSize(size: u16) void {
    switch (size) {
        8, 20, 32, 64 => {},
        else => die("hash_size must be 8, 20, 32 or 64, got {d}", .{size}),
    }
}

const Options = struct {
    io: Io,
    arena: Allocator,
    gpa: Allocator,
    ops: []const Json,
    file_id: u64,
    hash_id: ?xitdb.HashId,
    out_path: []const u8,
    allow_port_differences: bool,
    note_port_changes: bool,
};

/// what `offset_map: "disk"` keeps the offsets in, as test.zig does
const OffsetDB = xitdb.Database(.file, u64);

const DiskOffsets = struct {
    map: OffsetDB.HashMap(.read_write),

    pub fn reset(self: *DiskOffsets) !void {
        var cursor = self.map.cursor;
        try cursor.write(.{ .slot = null });
        self.map = try OffsetDB.HashMap(.read_write).init(cursor);
    }

    pub fn get(self: *DiskOffsets, source_offset: u64) !?u64 {
        const cursor = (try self.map.getCursor(source_offset)) orelse return null;
        return try cursor.readUint();
    }

    pub fn put(self: *DiskOffsets, source_offset: u64, target_offset: u64) !void {
        try self.map.put(source_offset, .{ .uint = target_offset });
    }
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
        // where a root cursor says it is, though it reads the root again each time
        const ROOT_HEADER_START = 20;
        const INITIAL_SIZE = 62;

        const Binding = union(enum) {
            rw: RW,
            ro: RO,
            slot: ?Slot,
            // what `read_path` found nothing for
            null_cursor,
            // an iterator changes as it's used, so it's held by pointer and never copied
            iter_rw: *RW.Iter,
            iter_ro: *RO.Iter,
            // what the replication ops pass around
            number: u64,
            replica_state: xitdb.ReplicaState,
            committed_bytes: *CommittedBytes,
        };

        const CommittedBytes = struct {
            data: []const u8,
            source: *Store,
            start: u64,
        };

        /// a database and the file it's in. the script's own is called main.
        const Store = struct {
            name: []const u8,
            db: DB,
            out: Io.File,
            out_path: []const u8,
            buffer: *Io.Writer.Allocating,
            read_only_file: ?Io.File = null,
            closed: bool = false,
            // bytes past the committed size are normal from when the file is written to
            // directly until a transaction next truncates them
            may_have_leftovers: bool = false,
            // applying bytes at 0 failed, so it's in no state to say what its size is
            broken: bool = false,
            // its committed size before the top-level op being run
            size_before: ?u64 = null,
            // the trailers of commits that are in its file
            trailers: std.ArrayList(Trailer) = .empty,
            // how many freezes it has had, including a concat's
            freezes: u64 = 0,
        };

        const Entry = struct {
            binding: Binding,
            // the top-level op it was bound in, to find uses after a rollback
            born: usize,
            // how many writes had been run by then, to find changes under an iterator
            writes: u64,
            // for --note-port-changes: how many freezes its database had had by then, and
            // whether it's the key cursor of a sorted pair
            freezes: u64 = 0,
            sorted_key: bool = false,
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

                r.bind(self.name, .{ .rw = cursor.* });
                r.callback_depth += 1;
                defer r.callback_depth -= 1;
                try r.execOps(self.ops);

                switch (r.env.get(self.name).?.binding) {
                    .rw => |c| cursor.* = c,
                    else => die("callback name \"{s}\" must hold a read-write cursor when the callback ends", .{self.name}),
                }
            }
        };

        arena: Allocator,
        gpa: Allocator = undefined,
        // when validating there is no database, and parsing a path only checks it
        store: *Store = undefined,
        stores: std.ArrayList(*Store) = .empty,
        validating: bool = false,
        io: Io = undefined,
        main_path: []const u8 = "",
        script_hash_id: ?xitdb.HashId = null,
        // what compaction with `offset_map: "memory"` uses, which it clears each time
        offset_map: std.AutoHashMap(u64, u64) = undefined,
        // the database a compaction wrote to, for the sidecar
        compacted_into: ?*Store = null,
        // what compaction with `offset_map: "disk"` uses
        offsets_file: ?Io.File = null,
        offsets: OffsetDB = undefined,
        // the names of the callbacks around the op being validated
        enclosing: std.ArrayList([]const u8) = .empty,
        env: std.StringHashMapUnmanaged(Entry) = .empty,
        // the top-level op being run, and the ones that rolled back
        top_index: usize = 0,
        rolled_back: std.AutoHashMapUnmanaged(usize, void) = .empty,
        // how many writes have been run, and how many had been when each top-level op ended
        writes: u64 = 0,
        writes_after_op: std.ArrayList(u64) = .empty,
        allow_port_differences: bool = false,
        note_port_changes: bool = false,
        callback_depth: usize = 0,
        // where in this transaction a failed op left something behind, which only
        // matters if the transaction goes on to commit
        failed_with_writes: std.ArrayList([]const u8) = .empty,
        // the storage behind a `root` reference by pointer
        root_cursor: RW = undefined,

        // validation: everything that can be known about a script without running it

        fn validateOps(self: *Self, ops: []const Json) void {
            for (ops, 0..) |op, i| {
                const saved_loc = pushOpLoc(i);
                defer loc_len = saved_loc;
                self.validateOp(op);
            }
        }

        fn validateOp(self: *Self, op_value: Json) void {
            const op = asObject(op_value, "an op");
            const name = asString(required(op, "op", "an op"), "op");
            const kind_of_op = std.meta.stringToEnum(OpKind, name) orelse die("\"{s}\" is not an op", .{name});
            checkKeys(op, opFields(kind_of_op), name);

            if (op.get("note")) |note| _ = asString(note, "note");
            if (op.get("expect_error")) |err| checkErrorName(asString(err, "expect_error"), name, self.allow_port_differences);
            switch (kind_of_op) {
                .run_context, .db_freeze, .fail => {},
                .close, .reopen, .raw_append, .raw_write, .create_database, .use, .compact, .replica_state, .replication_start, .committed_size, .read_committed, .apply_replicated => {
                    if (self.enclosing.items.len > 0) die("{s} can only be used at the top level", .{name});
                },
                else => checkName(asString(required(op, "on", name), "on"), "on"),
            }
            if (op.get("expect_null")) |v| _ = asBool(v, "expect_null");

            switch (kind_of_op) {
                .write_path => {
                    _ = self.parsePath(required(op, "path", name));
                    checkBindableField(op, "as");
                },
                .write, .write_if_empty => _ = self.parseData(required(op, "data", name)),
                .writer => {
                    if (op.get("format_tag")) |tag| _ = parseFixedBytes(2, self.arena, tag, "format_tag");
                    for (asArray(required(op, "steps", name), "steps")) |step_value| {
                        const step = onlyKey(asObject(step_value, "a writer step"), "a writer step");
                        if (isKey(step.key, "write")) {
                            _ = parseBytes(self.arena, step.value, "write");
                        } else if (isKey(step.key, "seek")) {
                            const offset = asInt(u64, step.value, "seek");
                            if (offset > MAX_SEEK) die("seek can't go past {d}, got {d}", .{ @as(u64, MAX_SEEK), offset });
                        } else die("a writer step must be \"write\" or \"seek\"", .{});
                    }
                },
                .freeze, .db_freeze => {},
                .run_context => _ = self.parseCtx(required(op, "ctx", name)),
                .fail => if (self.enclosing.items.len == 0) die("fail can only be used in a callback", .{}),
                .read_path => {
                    _ = self.parsePath(required(op, "path", name));
                    checkBindableField(op, "as");
                },
                .read_path_slot => {
                    _ = self.parsePath(required(op, "path", name));
                    checkBindableField(op, "as");
                    validateSlotExpectation(op);
                },
                .slot => {
                    checkBindableField(op, "as");
                    validateSlotExpectation(op);
                },
                .read_only => checkBindable(asString(required(op, "as", name), "as"), "as"),
                .read_key_value_pair => {
                    checkBindableField(op, "key_as");
                    checkBindableField(op, "value_as");
                    if (op.get("key_as")) |key_as| {
                        if (op.get("value_as")) |value_as| {
                            if (isKey(key_as.string, value_as.string)) die("key_as and value_as can't be the same name", .{});
                        }
                    }
                    if (op.get("expect_hash")) |hash| _ = self.parseHash(hash);
                },
                .read_uint, .count => if (op.get("expect")) |v| {
                    _ = asInt(u64, v, "expect");
                },
                .read_int => if (op.get("expect")) |v| {
                    _ = asInt(i64, v, "expect");
                },
                .read_float => if (op.get("expect")) |v| {
                    _ = parseHex64(self.arena, v, "expect");
                },
                .read_bytes => {
                    if (op.get("max_size")) |v| _ = asInt(u64, v, "max_size");
                    self.validateBytesExpectation(op);
                },
                .read_bytes_into => {
                    _ = checkedSize(required(op, "size", name), "size");
                    self.validateBytesExpectation(op);
                },
                .read_stream => {
                    if (op.get("buffer_size")) |v| _ = checkedSize(v, "buffer_size");
                    for (asArray(required(op, "steps", name), "steps")) |step_value| self.validateStreamStep(step_value);
                },
                .iterator => {
                    checkBindable(asString(required(op, "as", name), "as"), "as");
                    if (op.get("from_index") != null and op.get("from_key") != null) die("an iterator starts from an index or from a key, and not both", .{});
                    if (op.get("from_index")) |v| _ = parseIndex(v, "from_index");
                    if (op.get("from_key")) |v| _ = parseBytes(self.arena, v, "from_key");
                },
                .next => checkBindableField(op, "as"),
                .rank => {
                    _ = parseBytes(self.arena, required(op, "key", name), "key");
                    if (op.get("expect")) |v| _ = asInt(u64, v, "expect");
                },
                .close => {},
                .reopen => {
                    if (op.get("read_only")) |v| {
                        if (asBool(v, "read_only") and kind == .memory) die("the memory storage kind can't be opened read-only", .{});
                    }
                    if (op.get("hash_size")) |v| checkHashSize(asInt(u16, v, "hash_size"));
                },
                .raw_append => _ = parseBytes(self.arena, required(op, "bytes", name), "bytes"),
                .raw_write => {
                    _ = parseBytes(self.arena, required(op, "bytes", name), "bytes");
                    const offset = asInt(u64, required(op, "offset", name), "offset");
                    if (offset > MAX_SEEK) die("offset can't go past {d}, got {d}", .{ @as(u64, MAX_SEEK), offset });
                },
                .create_database => {
                    checkName(asString(required(op, "name", name), "name"), "name");
                    _ = parseHex64(self.arena, required(op, "file_id", name), "file_id");
                    if (op.get("hash_id")) |v| _ = parseHashId(self.arena, v);
                },
                .use => checkName(asString(required(op, "name", name), "name"), "name"),
                .compact => {
                    checkName(asString(required(op, "into", name), "into"), "into");
                    if (op.get("file_id")) |v| _ = parseHex64(self.arena, v, "file_id");
                    if (op.get("hash_id")) |v| _ = parseHashId(self.arena, v);
                    const offset_map = asString(required(op, "offset_map", name), "offset_map");
                    if (!isKey(offset_map, "memory") and !isKey(offset_map, "disk")) die("offset_map must be \"memory\" or \"disk\"", .{});
                },
                .replica_state => checkBindable(asString(required(op, "as", name), "as"), "as"),
                .replication_start => {
                    checkBindable(asString(required(op, "state", name), "state"), "state");
                    checkBindableField(op, "as");
                    if (op.get("expect")) |v| validateNumber(v, "expect");
                },
                .committed_size => {
                    checkBindableField(op, "as");
                    if (op.get("expect")) |v| validateNumber(v, "expect");
                },
                .read_committed => {
                    validateNumber(required(op, "start", name), "start");
                    validateNumber(required(op, "end", name), "end");
                    checkBindable(asString(required(op, "as", name), "as"), "as");
                    if (op.get("expect_same")) |v| checkBindable(asString(v, "expect_same"), "expect_same");
                },
                .apply_replicated => {
                    validateNumber(required(op, "start", name), "start");
                    checkBindable(asString(required(op, "bytes", name), "bytes"), "bytes");
                    if (op.get("short_by")) |v| _ = asInt(u64, v, "short_by");
                },
            }
        }

        /// an integer, or {"var": a name that holds one}
        fn validateNumber(v: Json, what: []const u8) void {
            switch (v) {
                .number_string => _ = asInt(u64, v, what),
                .object => |o| {
                    checkKeys(o, &.{"var"}, what);
                    checkBindable(asString(required(o, "var", what), "var"), "var");
                },
                else => die("{s} must be an integer or {{\"var\": ...}}", .{what}),
            }
        }

        fn number(self: *Self, v: Json, what: []const u8) u64 {
            if (v == .number_string) return asInt(u64, v, what);
            const name = v.object.get("var").?.string;
            return switch (self.lookup(name)) {
                .number => |n| n,
                else => die("\"{s}\" doesn't hold a number", .{name}),
            };
        }

        fn checkNumber(self: *Self, op: ObjectMap, got: u64) void {
            const want = self.number(op.get("expect") orelse return, "expect");
            if (got != want) die("expected {d}, got {d}", .{ want, got });
        }

        fn validateBytesExpectation(self: *Self, op: ObjectMap) void {
            if (op.get("expect")) |v| _ = parseBytes(self.arena, v, "expect");
            if (op.get("expect_format_tag")) |v| {
                if (v != .null) _ = parseFixedBytes(2, self.arena, v, "expect_format_tag");
            }
        }

        fn validateStreamStep(self: *Self, step_value: Json) void {
            const step = asObject(step_value, "a stream step");
            if (step.get("seek")) |v| {
                checkKeys(step, &.{"seek"}, "a seek step");
                _ = asInt(u64, v, "seek");
            } else if (step.get("position")) |v| {
                checkKeys(step, &.{"position"}, "a position step");
                _ = asInt(u64, v, "position");
            } else if (step.get("read")) |v| {
                checkKeys(step, &.{ "read", "expect" }, "a read step");
                _ = checkedSize(v, "read");
                if (step.get("expect")) |bytes| _ = parseBytes(self.arena, bytes, "expect");
            } else if (step.get("read_all")) |v| {
                checkKeys(step, &.{ "read_all", "expect" }, "a read_all step");
                _ = checkedSize(v, "read_all");
                if (step.get("expect")) |bytes| _ = parseBytes(self.arena, bytes, "expect");
            } else die("a stream step must be \"read\", \"read_all\", \"seek\" or \"position\"", .{});
        }

        /// a size that gets allocated, which a script has no need to make huge
        fn checkedSize(v: Json, what: []const u8) usize {
            const size = asInt(usize, v, what);
            if (size > MAX_SEEK) die("{s} can't go past {d}, got {d}", .{ what, @as(u64, MAX_SEEK), size });
            return size;
        }

        fn validateSlotExpectation(op: ObjectMap) void {
            const want = asObject(op.get("expect") orelse return, "expect");
            checkKeys(want, &.{ "tag", "value", "full" }, "expect");
            if (want.count() == 0) die("expect needs at least one of tag, value and full", .{});
            if (want.get("tag")) |tag| _ = parseTag(asString(tag, "tag"));
            if (want.get("value")) |value| _ = asInt(u64, value, "value");
            if (want.get("full")) |full| _ = asBool(full, "full");
        }

        // names

        fn bind(self: *Self, name: []const u8, binding: Binding) void {
            var freezes: u64 = 0;
            if (dbOf(binding)) |db| {
                if (self.storeOf(db)) |store| freezes = store.freezes;
            }
            self.env.put(self.arena, name, .{ .binding = binding, .born = self.top_index, .writes = self.writes, .freezes = freezes }) catch die("out of memory", .{});
        }

        /// the database a cursor or an iterator belongs to
        fn dbOf(binding: Binding) ?*DB {
            return switch (binding) {
                .rw => |c| c.db,
                .ro => |c| c.db,
                .iter_rw => |i| i.cursor.db,
                .iter_ro => |i| i.cursor.db,
                else => null,
            };
        }

        fn entryFor(self: *Self, name: []const u8) *Entry {
            const entry = self.env.getPtr(name) orelse die("\"{s}\" is not bound", .{name});
            if (self.rolled_back.contains(entry.born)) die("\"{s}\" comes from a transaction that was rolled back, which is an undefined use", .{name});
            return entry;
        }

        fn lookup(self: *Self, name: []const u8) Binding {
            if (isKey(name, "root")) return .{ .rw = self.store.db.rootCursor() };
            return self.entryFor(name).binding;
        }

        fn cursorName(op: ObjectMap) []const u8 {
            return op.get("on").?.string;
        }

        /// the cursor called `name` as a value, for methods that don't change it
        fn rwValue(self: *Self, name: []const u8) RW {
            return switch (self.lookup(name)) {
                .rw => |c| c,
                .ro => die("\"{s}\" is a read-only cursor", .{name}),
                .slot => die("\"{s}\" is a slot, not a cursor", .{name}),
                .null_cursor => die("\"{s}\" is a null cursor", .{name}),
                .iter_rw, .iter_ro => die("\"{s}\" is an iterator, not a cursor", .{name}),
                .number, .replica_state, .committed_bytes => die("\"{s}\" holds something for replication, not a cursor", .{name}),
            };
        }

        /// the cursor called `name` by pointer, for methods that update it
        fn rwPointer(self: *Self, name: []const u8) *RW {
            if (isKey(name, "root")) {
                self.root_cursor = self.store.db.rootCursor();
                return &self.root_cursor;
            }
            return switch (self.entryFor(name).binding) {
                .rw => |*c| c,
                .ro => die("\"{s}\" is a read-only cursor", .{name}),
                .slot => die("\"{s}\" is a slot, not a cursor", .{name}),
                .null_cursor => die("\"{s}\" is a null cursor", .{name}),
                .iter_rw, .iter_ro => die("\"{s}\" is an iterator, not a cursor", .{name}),
                .number, .replica_state, .committed_bytes => die("\"{s}\" holds something for replication, not a cursor", .{name}),
            };
        }

        /// the cursor called `name`, read-write or read-only
        fn anyCursor(self: *Self, name: []const u8) Binding {
            const binding = self.lookup(name);
            return switch (binding) {
                .rw, .ro => binding,
                .slot => die("\"{s}\" is a slot, not a cursor", .{name}),
                .null_cursor => die("\"{s}\" is a null cursor", .{name}),
                .iter_rw, .iter_ro => die("\"{s}\" is an iterator, not a cursor", .{name}),
                .number, .replica_state, .committed_bytes => die("\"{s}\" holds something for replication, not a cursor", .{name}),
            };
        }

        fn wrap(cursor: anytype) Binding {
            return if (@TypeOf(cursor) == RW) .{ .rw = cursor } else .{ .ro = cursor };
        }

        fn wrapIterator(iter: anytype) Binding {
            return if (@TypeOf(iter) == *RW.Iter) .{ .iter_rw = iter } else .{ .iter_ro = iter };
        }

        fn storeOf(self: *Self, db: *DB) ?*Store {
            for (self.stores.items) |store| {
                if (&store.db == db) return store;
            }
            return null;
        }

        fn noteChange(self: *Self, comptime id: []const u8) void {
            std.debug.print("change {s} {s}\n", .{ id, loc_buf[0..loc_len] });
            _ = self;
        }

        /// what the port's guards will have to say about a write through this name
        fn noteWrite(self: *Self, name: []const u8, path: ?[]const Json) void {
            if (!self.note_port_changes) return;
            if (isKey(name, "root")) return;
            const entry = self.env.getPtr(name) orelse return;
            const cursor = switch (entry.binding) {
                .rw => |c| c,
                else => return,
            };
            // each write through a root cursor is a transaction of its own
            if (cursor.slot_ptr.position == ROOT_HEADER_START) return;

            if (entry.sorted_key) self.noteChange("2");
            if (entry.born != self.top_index) {
                if (cursor.db.tx_start != null) self.noteChange("1-writes") else self.noteChange("1-raises");
                return;
            }
            const store = self.storeOf(cursor.db) orelse return;
            if (entry.freezes < store.freezes) {
                const only_init = if (path) |parts| parts.len == 1 and isInitPart(parts[0]) else false;
                if (only_init) self.noteChange("18-init") else self.noteChange("18-other");
            }
        }

        /// a read through a cursor or an iterator made before the last freeze, which the port
        /// goes on allowing as a snapshot read, so these are what hold it to that. a slot isn't
        /// counted, as that's the cursor's snapshot and doesn't go to the file. a cursor made
        /// from a stale one is counted where it was made, and is fresh by the rule that the
        /// port's guard goes by when a cursor was made
        fn noteRead(self: *Self, name: []const u8) void {
            if (!self.note_port_changes or isKey(name, "root")) return;
            const entry = self.env.getPtr(name) orelse return;
            const db = dbOf(entry.binding) orelse return;
            // a root cursor reads the last commit, so it's never stale
            const position = switch (entry.binding) {
                .rw => |c| c.slot_ptr.position,
                .ro => |c| c.slot_ptr.position,
                else => null,
            };
            if (position == ROOT_HEADER_START) return;
            const store = self.storeOf(db) orelse return;
            if (entry.freezes >= store.freezes) return;
            if (entry.born == self.top_index) self.noteChange("18-reads") else self.noteChange("18-reads-earlier");
        }

        fn isInitPart(part: Json) bool {
            const name = switch (part) {
                .string => |s| s,
                .object => |o| o.keys()[0],
                else => return false,
            };
            return std.mem.endsWith(u8, name, "_init");
        }

        fn partName(part: Json) []const u8 {
            return switch (part) {
                .string => |s| s,
                .object => |o| o.keys()[0],
                else => "",
            };
        }

        fn notePath(self: *Self, path: []const Json) void {
            if (!self.note_port_changes) return;
            for (path, 0..) |part, i| {
                const name = partName(part);
                if (isKey(name, "linked_array_list_concat")) self.noteChange("22");
                if ((isKey(name, "hash_map_remove") or isKey(name, "sorted_map_remove")) and i + 1 < path.len) self.noteChange("12");
            }
        }

        /// write_if_empty goes by the snapshot, and the port will go by the slot as it is now
        fn noteWriteIfEmpty(self: *Self, name: []const u8) !void {
            if (!self.note_port_changes or isKey(name, "root")) return;
            const entry = self.env.getPtr(name) orelse return;
            const cursor = switch (entry.binding) {
                .rw => |c| c,
                else => return,
            };
            const position = cursor.slot_ptr.position orelse return;
            if (position == ROOT_HEADER_START) return;
            var reader = cursor.db.core.reader();
            try reader.seekTo(position);
            var bytes: [9]u8 = undefined;
            try reader.interface.readSliceAll(&bytes);
            const current: Slot = @bitCast(std.mem.readInt(u72, &bytes, .big));
            if (cursor.slot_ptr.slot.empty() and !current.empty()) self.noteChange("17-overwrites");
            if (!cursor.slot_ptr.slot.empty() and current.empty()) self.noteChange("17-holds-back");
        }

        /// the behaviours a valid script can't use, because the port corrects them
        fn portDiffers(self: *Self, what: []const u8) void {
            if (!self.allow_port_differences) die("{s} is a behaviour the port corrects, so a valid script can't use it", .{what});
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
                        if (self.validating) {
                            checkBindable(name, "var");
                            return Slot{};
                        }
                        return switch (self.lookup(name)) {
                            .slot => |s| s,
                            else => die("\"{s}\" is not a slot", .{name}),
                        };
                    }
                    checkKeys(o, &.{ "tag", "value", "full" }, "a literal slot");
                    const tag = parseTag(asString(required(o, "tag", "a literal slot"), "tag"));
                    switch (tag) {
                        .none, .short_bytes, .uint, .int, .float => {},
                        else => die("a literal slot can't have the tag {s}, whose value is a file offset", .{@tagName(tag)}),
                    }
                    return .{
                        .tag = tag,
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
            if (isKey(only.key, "slot")) {
                const slot = self.parseSlot(only.value);
                if (slot) |s| {
                    switch (s.tag) {
                        // part of a collection's structure. written anywhere, the engine
                        // would follow it as if it had been built there, which is an undefined use
                        .index, .kv_pair, .sorted_kv_pair => die("a slot with the tag {s} can't be written, which is an undefined use", .{@tagName(s.tag)}),
                        else => {},
                    }
                }
                return .{ .slot = slot };
            }
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
            const name = asString(required(o, "as", "a callback"), "as");
            const ops = asArray(required(o, "ops", "a callback"), "ops");
            if (self.validating) {
                checkBindable(name, "a callback's as");
                if (self.enclosing.items.len == MAX_CALLBACK_DEPTH) die("callbacks can't nest more than {d} deep", .{@as(u32, MAX_CALLBACK_DEPTH)});
                for (self.enclosing.items) |enclosing| {
                    if (isKey(enclosing, name)) die("callback name \"{s}\" is already used by a callback around this one", .{name});
                }
                self.enclosing.append(self.arena, name) catch die("out of memory", .{});
                defer _ = self.enclosing.pop();
                const saved_loc = pushLoc("/ctx:{s}", .{name});
                defer loc_len = saved_loc;
                self.validateOps(ops);
            }
            return .{ .runner = self, .name = name, .ops = ops };
        }

        // expectations

        fn checkNull(op: ObjectMap, is_null: bool) void {
            const v = op.get("expect_null") orelse return;
            if (v.bool != is_null) die("expected a {s} result, got a {s} one", .{ if (v.bool) "null" else "non-null", if (is_null) "null" else "non-null" });
        }

        fn checkBytes(self: *Self, op: ObjectMap, got: anytype) void {
            if (op.get("expect")) |v| {
                const want = parseBytes(self.arena, v, "expect");
                if (!std.mem.eql(u8, got.value, want)) die("expected bytes \"{s}\", got \"{s}\"", .{ want, got.value });
            }
            if (op.get("expect_format_tag")) |v| {
                const want: ?[2]u8 = if (v == .null) null else parseFixedBytes(2, self.arena, v, "expect_format_tag");
                if (want == null and got.format_tag != null) die("expected no format tag, got one", .{});
                if (want != null and (got.format_tag == null or !std.mem.eql(u8, &want.?, &got.format_tag.?))) die("expected a different format tag", .{});
            }
        }

        fn checkSlot(op: ObjectMap, slot: ?Slot) void {
            const v = op.get("expect") orelse return;
            const want = v.object;
            const s = slot orelse die("expected a slot, got null", .{});
            if (want.get("tag")) |tag| {
                if (s.tag != parseTag(tag.string)) die("expected tag {s}, got {s}", .{ tag.string, @tagName(s.tag) });
            }
            if (want.get("value")) |value| {
                const n = asInt(u64, value, "value");
                if (s.value != n) die("expected slot value {d}, got {d}", .{ n, s.value });
            }
            if (want.get("full")) |full| {
                if (s.full != full.bool) die("expected full={}, got full={}", .{ full.bool, s.full });
            }
        }

        // ops

        fn execOps(self: *Self, ops: []const Json) anyerror!void {
            for (ops, 0..) |op, i| {
                const saved_loc = pushOpLoc(i);
                defer loc_len = saved_loc;
                try self.execOp(op.object);
            }
        }

        /// runs one op. with `expect_error` the op must fail with that error, which
        /// ends here; without it, an error is returned to whoever is running the
        /// ops, the way `try` would in a Zig callback.
        fn execOp(self: *Self, op: ObjectMap) anyerror!void {
            const expected: ?[]const u8 = if (op.get("expect_error")) |v| v.string else null;
            // a failed op that left something behind, which only the memory kind can tell
            const before: ?[]const u8 = if (self.note_port_changes and kind == .memory and expected != null and self.callback_depth > 0)
                self.arena.dupe(u8, self.store.buffer.written()) catch die("out of memory", .{})
            else
                null;
            const result = self.dispatch(op);
            if (before) |bytes| {
                if (result) |_| {} else |_| {
                    if (!std.mem.eql(u8, bytes, self.store.buffer.written())) {
                        const where = self.arena.dupe(u8, loc_buf[0..loc_len]) catch die("out of memory", .{});
                        self.failed_with_writes.append(self.arena, where) catch die("out of memory", .{});
                    }
                }
            }
            if (result) |_| {} else |_| noteErrorLoc();
            const want = expected orelse return result;
            if (result) |_| {
                die("expected error {s}, but the op succeeded", .{want});
            } else |err| {
                if (!std.mem.eql(u8, @errorName(err), want)) die("expected error {s}, got {s}, which started at {s}", .{ want, @errorName(err), error_loc_buf[0..error_loc_len] });
                error_loc_len = 0;
            }
        }

        fn initOpts(store: *Store, file: Io.File, file_id: ?u64, hash_id: ?xitdb.HashId) xitdb.InitOpts(kind) {
            return switch (kind) {
                .memory => .{ .buffer = store.buffer, .hash_id = hash_id, .file_id = file_id },
                .file => .{ .file = file, .fsync = false, .hash_id = hash_id, .file_id = file_id },
                .buffered_file => .{ .file = file, .buffer = store.buffer, .fsync = false, .hash_id = hash_id, .file_id = file_id },
            };
        }

        /// opening with a hash size that isn't the file's fails, and that's all it's good for
        fn openAs(self: *Self, comptime OtherHashInt: type) !void {
            _ = try xitdb.Database(kind, OtherHashInt).init(self.io, initOpts(self.store, self.store.out, null, null));
            die("the database opened with a hash size that isn't the script's, which is an undefined use", .{});
        }

        fn findStore(self: *Self, name: []const u8) ?*Store {
            for (self.stores.items) |store| {
                if (isKey(store.name, name)) return store;
            }
            return null;
        }

        /// <out>.<name>.db, next to <out>.db
        fn pathFor(self: *Self, name: []const u8) []const u8 {
            const stem = if (std.mem.endsWith(u8, self.main_path, ".db")) self.main_path[0 .. self.main_path.len - 3] else self.main_path;
            return std.mem.concat(self.arena, u8, &.{ stem, ".", name, ".db" }) catch die("out of memory", .{});
        }

        /// a new file for a database, with no database in it yet
        fn newStore(self: *Self, name: []const u8) !*Store {
            const store = self.arena.create(Store) catch die("out of memory", .{});
            const path = self.pathFor(name);
            const buffer = self.arena.create(Io.Writer.Allocating) catch die("out of memory", .{});
            buffer.* = Io.Writer.Allocating.init(self.gpa);
            store.* = .{
                .name = name,
                .db = undefined,
                .out = try Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .truncate = true }),
                .out_path = path,
                .buffer = buffer,
            };
            return store;
        }

        fn offsetsPath(self: *Self) []const u8 {
            return std.mem.concat(self.arena, u8, &.{ self.main_path, ".offsets" }) catch die("out of memory", .{});
        }

        fn compactWithDiskOffsets(self: *Self, opts: xitdb.InitOpts(kind)) !DB {
            // one for the whole script, like test.zig's, so that a compaction has to forget
            // the last one. it has commit IDs of its own, which go nowhere, as this file doesn't either
            if (self.offsets_file == null) {
                self.offsets_file = try Io.Dir.cwd().createFile(self.io, self.offsetsPath(), .{ .read = true, .truncate = true });
                self.offsets = try OffsetDB.init(self.io, .{ .file = self.offsets_file.?, .fsync = false });
            }
            var result: DB = undefined;
            const InTransaction = struct {
                source: *DB,
                opts: xitdb.InitOpts(kind),
                result: *DB,

                pub fn run(ctx: @This(), cursor: *OffsetDB.Cursor(.read_write)) !void {
                    var map = DiskOffsets{ .map = try OffsetDB.HashMap(.read_write).init(cursor.*) };
                    ctx.result.* = try ctx.source.compact(kind, ctx.opts, &map);
                }
            };
            try self.offsets.runContext(InTransaction{ .source = &self.store.db, .opts = opts, .result = &result });
            return result;
        }

        fn compact(self: *Self, op: ObjectMap) !void {
            const into = op.get("into").?.string;
            const existing = self.findStore(into);
            if (existing) |store| {
                if (store.closed) die("database \"{s}\" is closed", .{into});
                if (op.get("file_id") != null) die("database \"{s}\" already has a file ID", .{into});
            } else if (op.get("file_id") == null) die("compacting into a new database needs a file_id", .{});

            const target = existing orelse try self.newStore(into);
            errdefer if (existing == null) {
                target.out.close(self.io);
                Io.Dir.cwd().deleteFile(self.io, target.out_path) catch {};
            };
            if (existing) |store| try store.db.core.flush();

            const file_id: ?u64 = if (op.get("file_id")) |v| parseHex64(self.arena, v, "file_id") else null;
            const hash_id: ?xitdb.HashId = if (op.get("hash_id")) |v| parseHashId(self.arena, v) else null;
            const opts = initOpts(target, target.out, file_id, hash_id);
            if (isKey(op.get("offset_map").?.string, "disk")) {
                target.db = try self.compactWithDiskOffsets(opts);
            } else {
                target.db = try self.store.db.compact(kind, opts, &self.offset_map);
            }

            if (existing == null) {
                target.size_before = INITIAL_SIZE;
                self.stores.append(self.arena, target) catch die("out of memory", .{});
            }
            self.compacted_into = target;
        }

        fn removeTrailersFrom(store: *Store, position: u64) void {
            var kept: usize = 0;
            for (store.trailers.items) |trailer| {
                if (trailer.position < position) {
                    store.trailers.items[kept] = trailer;
                    kept += 1;
                }
            }
            store.trailers.shrinkRetainingCapacity(kept);
        }

        fn applyReplicated(self: *Self, op: ObjectMap) !void {
            const store = self.store;
            const start = self.number(op.get("start").?, "start");
            const name = op.get("bytes").?.string;
            const bytes = switch (self.lookup(name)) {
                .committed_bytes => |b| b,
                else => die("\"{s}\" doesn't hold committed bytes", .{name}),
            };
            const short_by: usize = if (op.get("short_by")) |v| asInt(usize, v, "short_by") else 0;
            if (short_by > bytes.data.len) die("short_by can't be more than the {d} bytes there are", .{bytes.data.len});
            const data = bytes.data[0 .. bytes.data.len - short_by];

            // whether it gets as far as writing
            const committed: ?u64 = store.db.committedSize() catch null;
            const writes = start == 0 or (committed != null and committed.? == start);
            if (writes and start != bytes.start) die("these bytes were read from {d}, and applying them at {d} isn't something a script can say what it means", .{ bytes.start, start });

            var reader = Io.Reader.fixed(data);
            const result = store.db.applyReplicated(start, &reader, data.len);

            if (writes) {
                removeTrailersFrom(store, start);
                for (bytes.source.trailers.items) |trailer| {
                    if (trailer.position >= start and trailer.position < start + data.len) {
                        store.trailers.append(self.arena, trailer) catch die("out of memory", .{});
                    }
                }
                if (result) |_| {
                    store.broken = false;
                } else |_| {
                    store.may_have_leftovers = true;
                    if (start == 0) store.broken = true;
                }
            }
            return result;
        }

        fn makeIterator(self: *Self, cursor: anytype, op: ObjectMap) !@TypeOf(cursor).Iter {
            const Iter = @TypeOf(cursor).Iter;
            if (op.get("from_key")) |v| return Iter.initSortedFromKey(cursor, parseBytes(self.arena, v, "from_key"));
            if (op.get("from_index")) |v| {
                const index = parseIndex(v, "from_index");
                // each collection has its own call for this, and the others raise UnexpectedTag from any of them
                return switch ((try cursor.slot()).tag) {
                    .array_list => Iter.initArrayListFromIndex(cursor, index),
                    .linked_array_list => Iter.initLinkedArrayListFromIndex(cursor, index),
                    else => Iter.initSortedFromIndex(cursor, index),
                };
            }
            return cursor.iterator();
        }

        /// an iterator keeps copies of the blocks it's part way through and reads the others
        /// when it gets to them. so whatever is rewritten in place while it's running might
        /// show or not, and that's nothing a second implementation should have to match.
        fn checkIteratorUse(self: *Self, name: []const u8, entry: *const Entry) void {
            const writes_by_then = if (entry.born == self.top_index) self.writes else self.writes_after_op.items[entry.born];
            if (writes_by_then != entry.writes) die("iterator \"{s}\" is being used after a write in the transaction that made it, which is an undefined use", .{name});
        }

        /// an iterator stops after giving as many elements as a list has, and not at the end
        /// of the list. it skips what was never written, and a slice leaves what's past the new
        /// end in its blocks, so it can give what the list no longer has.
        fn isPastEndOfList(iter: anytype) bool {
            if (iter.cursor.slot_ptr.slot.tag != .array_list) return false;
            const levels = iter.core.stack.slice();
            var position: u64 = 0;
            for (levels, 0..) |level, i| {
                // it has moved on from what it just gave
                const index: u64 = if (i == levels.len - 1) level.index - 1 else level.index;
                position = position * 16 + index;
            }
            return position >= iter.core.size;
        }

        /// Cursor.reader takes a short value's length from the cursor and its bytes from
        /// the file, and needs the slot's position for that
        fn checkStreamable(self: *Self, cursor: anytype) !void {
            const slot = try cursor.slot();
            switch (slot.tag) {
                .none => self.portDiffers("streaming a slot set to nothing"),
                .short_bytes => {
                    const position = cursor.slot_ptr.position orelse return self.portDiffers("streaming a short value from a cursor with no position");
                    if (position == ROOT_HEADER_START) return;
                    var reader = cursor.db.core.reader();
                    try reader.seekTo(position);
                    var bytes: [9]u8 = undefined;
                    try reader.interface.readSliceAll(&bytes);
                    const current: Slot = @bitCast(std.mem.readInt(u72, &bytes, .big));
                    if (!current.eql(slot)) self.portDiffers("streaming a short value after its slot has been overwritten");
                },
                else => {},
            }
        }

        fn streamStep(self: *Self, reader: anytype, step: ObjectMap) !void {
            if (step.get("seek")) |v| {
                try reader.seekTo(asInt(u64, v, "seek"));
            } else if (step.get("position")) |v| {
                const want = asInt(u64, v, "position");
                const got = reader.logicalPos();
                if (got != want) die("expected the stream to be at {d}, but it's at {d}", .{ want, got });
            } else {
                const all = step.get("read_all");
                const size = asInt(usize, all orelse step.get("read").?, "read");
                const bytes = self.arena.alloc(u8, size) catch die("out of memory", .{});
                var got: []const u8 = bytes;
                if (all != null) {
                    try reader.interface.readSliceAll(bytes);
                } else {
                    got = bytes[0..try reader.interface.readSliceShort(bytes)];
                }
                if (step.get("expect")) |v| {
                    const want = parseBytes(self.arena, v, "expect");
                    if (!std.mem.eql(u8, got, want)) die("expected the stream to give \"{s}\", and it gave \"{s}\"", .{ want, got });
                }
            }
        }

        fn writeRaw(self: *Self, offset: u64, bytes: []const u8) !void {
            if (kind == .memory) {
                var writer = self.store.db.core.writer();
                try writer.seekTo(offset);
                try writer.interface.writeAll(bytes);
            } else {
                try self.store.out.writePositionalAll(self.io, bytes, offset);
            }
            // what's written over a trailer's commit ID isn't random any more
            var kept: usize = 0;
            for (self.store.trailers.items) |trailer| {
                if (offset < trailer.position + TRAILER_SIZE and offset + bytes.len > trailer.position) continue;
                self.store.trailers.items[kept] = trailer;
                kept += 1;
            }
            self.store.trailers.shrinkRetainingCapacity(kept);
        }

        fn dispatch(self: *Self, op: ObjectMap) anyerror!void {
            const kind_of_op = std.meta.stringToEnum(OpKind, op.get("op").?.string).?;

            switch (kind_of_op) {
                .close, .reopen, .raw_append, .raw_write, .create_database, .use => {},
                else => if (self.store.closed) die("the database is closed", .{}),
            }

            switch (kind_of_op) {
                .read_path, .read_path_slot, .read_key_value_pair, .read_uint, .read_int, .read_float, .read_bytes, .read_bytes_into, .read_stream, .count, .iterator, .next, .rank => self.noteRead(cursorName(op)),
                else => {},
            }

            switch (kind_of_op) {
                .create_database => {
                    const name = op.get("name").?.string;
                    if (self.findStore(name) != null) die("there's already a database called \"{s}\"", .{name});
                    const hash_id = if (op.get("hash_id")) |v| parseHashId(self.arena, v) else self.script_hash_id;
                    const store = try self.newStore(name);
                    store.db = try DB.init(self.io, initOpts(store, store.out, parseHex64(self.arena, op.get("file_id").?, "file_id"), hash_id));
                    store.size_before = INITIAL_SIZE;
                    self.stores.append(self.arena, store) catch die("out of memory", .{});
                },
                .use => {
                    const name = op.get("name").?.string;
                    self.store = self.findStore(name) orelse die("there's no database called \"{s}\"", .{name});
                },
                .compact => try self.compact(op),
                .replica_state => self.bind(op.get("as").?.string, .{ .replica_state = try self.store.db.replicaState() }),
                .replication_start => {
                    const name = op.get("state").?.string;
                    const state = switch (self.lookup(name)) {
                        .replica_state => |state| state,
                        else => die("\"{s}\" doesn't hold a replica's state", .{name}),
                    };
                    const start = try self.store.db.replicationStart(state);
                    self.checkNumber(op, start);
                    if (op.get("as")) |as| self.bind(as.string, .{ .number = start });
                },
                .committed_size => {
                    const size = try self.store.db.committedSize();
                    self.checkNumber(op, size);
                    if (op.get("as")) |as| self.bind(as.string, .{ .number = size });
                },
                .read_committed => {
                    const start = self.number(op.get("start").?, "start");
                    const end = self.number(op.get("end").?, "end");
                    var writer = Io.Writer.Allocating.init(self.arena);
                    try self.store.db.readCommitted(start, end, &writer.writer);
                    if (op.get("expect_same")) |v| {
                        const other = switch (self.lookup(v.string)) {
                            .committed_bytes => |b| b,
                            else => die("\"{s}\" doesn't hold committed bytes", .{v.string}),
                        };
                        if (!std.mem.eql(u8, writer.written(), other.data)) die("the {d} bytes read aren't the same as the {d} in \"{s}\"", .{ writer.written().len, other.data.len, v.string });
                    }
                    const bytes = self.arena.create(CommittedBytes) catch die("out of memory", .{});
                    bytes.* = .{ .data = writer.written(), .source = self.store, .start = start };
                    self.bind(op.get("as").?.string, .{ .committed_bytes = bytes });
                },
                .apply_replicated => try self.applyReplicated(op),
                .close => {
                    if (self.store.closed) die("the database is already closed", .{});
                    try self.store.db.core.flush();
                    if (self.store.read_only_file) |file| {
                        file.close(self.io);
                        self.store.read_only_file = null;
                    }
                    self.env.clearRetainingCapacity();
                    self.store.closed = true;
                },
                .reopen => {
                    if (!self.store.closed) die("the database is already open", .{});
                    if (op.get("hash_size")) |v| {
                        const size = asInt(u16, v, "hash_size");
                        if (size != HASH_SIZE) {
                            switch (size) {
                                8 => try self.openAs(u64),
                                20 => try self.openAs(u160),
                                32 => try self.openAs(u256),
                                64 => try self.openAs(u512),
                                else => unreachable,
                            }
                        }
                    }
                    const read_only = if (op.get("read_only")) |v| v.bool else false;
                    const file: Io.File = if (read_only) try Io.Dir.cwd().openFile(self.io, self.store.out_path, .{ .mode = .read_only }) else self.store.out;
                    errdefer if (read_only) file.close(self.io);
                    self.store.db = DB.init(self.io, initOpts(self.store, file, null, null)) catch |err| {
                        if (self.note_port_changes and (err == error.InvalidDatabase or err == error.TruncatedDatabase)) self.noteChange("19");
                        return err;
                    };
                    if (read_only) self.store.read_only_file = file;
                    self.store.closed = false;
                    self.store.broken = false;
                },
                .raw_append => {
                    if (!self.store.closed) die("the file can only be written to directly while the database is closed", .{});
                    const end = if (kind == .memory) self.store.buffer.written().len else try self.store.out.length(self.io);
                    try self.writeRaw(end, parseBytes(self.arena, op.get("bytes").?, "bytes"));
                    self.store.may_have_leftovers = true;
                },
                .raw_write => {
                    if (!self.store.closed) die("the file can only be written to directly while the database is closed", .{});
                    try self.writeRaw(asInt(u64, op.get("offset").?, "offset"), parseBytes(self.arena, op.get("bytes").?, "bytes"));
                    self.store.may_have_leftovers = true;
                },
                .write_path => {
                    self.writes += 1;
                    const cursor = self.rwValue(cursorName(op));
                    const path = self.parsePath(op.get("path").?);
                    const path_json = op.get("path").?.array.items;
                    if (path_json.len > 0) {
                        self.noteWrite(cursorName(op), path_json);
                        self.notePath(path_json);
                    }
                    const concat = for (path_json) |part| {
                        if (isKey(partName(part), "linked_array_list_concat")) break true;
                    } else false;
                    if (self.store.read_only_file != null) {
                        for (path) |part| {
                            if (part == .ctx) die("a callback on a read-only file runs or doesn't depending on the storage kind, which is an undefined use", .{});
                        }
                    }
                    const next = try cursor.writePath(Ctx, path);
                    // a concat freezes everything, and what it gives back is what's refreshed
                    if (concat) {
                        if (self.storeOf(cursor.db)) |store| store.freezes += 1;
                    }
                    if (op.get("as")) |as| self.bind(as.string, .{ .rw = next });
                },
                .write => {
                    self.writes += 1;
                    self.noteWrite(cursorName(op), null);
                    const data = self.parseData(op.get("data").?);
                    try self.rwPointer(cursorName(op)).write(data);
                },
                .write_if_empty => {
                    self.writes += 1;
                    self.noteWrite(cursorName(op), null);
                    try self.noteWriteIfEmpty(cursorName(op));
                    const data = self.parseData(op.get("data").?);
                    try self.rwPointer(cursorName(op)).writeIfEmpty(data);
                },
                .writer => {
                    self.writes += 1;
                    self.noteWrite(cursorName(op), null);
                    const format_tag: ?[2]u8 = if (op.get("format_tag")) |tag| parseFixedBytes(2, self.arena, tag, "format_tag") else null;
                    var writer = try self.rwPointer(cursorName(op)).writer(&.{});
                    writer.format_tag = format_tag;
                    for (op.get("steps").?.array.items) |step_value| {
                        const step = onlyKey(step_value.object, "a writer step");
                        if (isKey(step.key, "write")) {
                            try writer.interface.writeAll(parseBytes(self.arena, step.value, "write"));
                        } else {
                            try writer.seekTo(asInt(u64, step.value, "seek"));
                        }
                    }
                    try writer.finish();
                },
                .freeze => {
                    if (self.note_port_changes) self.noteChange("23");
                    try self.rwPointer(cursorName(op)).freeze();
                },
                .db_freeze => {
                    try self.store.db.freeze();
                    self.store.freezes += 1;
                },
                .run_context => {
                    if (self.store.read_only_file != null) die("a callback on a read-only file runs or doesn't depending on the storage kind, which is an undefined use", .{});
                    try self.store.db.runContext(self.parseCtx(op.get("ctx").?));
                },
                .fail => return error.ScriptAbort,
                .read_path => {
                    const path = self.parsePath(op.get("path").?);
                    const result = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readPath(Ctx, path),
                        else => unreachable,
                    };
                    checkNull(op, result == null);
                    if (op.get("as")) |as| self.bind(as.string, if (result) |c| .{ .ro = c } else .null_cursor);
                },
                .read_path_slot => {
                    const path = self.parsePath(op.get("path").?);
                    const result = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readPathSlot(Ctx, path),
                        else => unreachable,
                    };
                    checkNull(op, result == null);
                    checkSlot(op, result);
                    if (op.get("as")) |as| self.bind(as.string, .{ .slot = result });
                },
                .slot => {
                    const result = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.slot(),
                        else => unreachable,
                    };
                    checkSlot(op, result);
                    if (op.get("as")) |as| self.bind(as.string, .{ .slot = result });
                },
                .read_only => {
                    const result = self.rwValue(cursorName(op)).readOnly();
                    self.bind(op.get("as").?.string, .{ .ro = result });
                },
                .read_key_value_pair => {
                    switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| {
                            const pair = try c.readKeyValuePair();
                            if (op.get("expect_hash")) |hash| {
                                const want = self.parseHash(hash);
                                if (pair.hash != want) die("expected hash {x}, got {x}", .{ want, pair.hash });
                            }
                            if (op.get("key_as")) |as| {
                                self.bind(as.string, wrap(pair.key_cursor));
                                const slot = try c.slot();
                                if (slot.tag == .sorted_kv_pair) self.env.getPtr(as.string).?.sorted_key = true;
                            }
                            if (op.get("value_as")) |as| self.bind(as.string, wrap(pair.value_cursor));
                        },
                        else => unreachable,
                    }
                },
                .read_uint => {
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
                    const max_size: ?usize = if (op.get("max_size")) |v| asInt(usize, v, "max_size") else null;
                    const got = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| try c.readBytesObjectAlloc(self.arena, max_size),
                        else => unreachable,
                    };
                    self.checkBytes(op, got);
                },
                .read_bytes_into => {
                    const size = asInt(usize, op.get("size").?, "size");
                    const buffer = self.arena.alloc(u8, size) catch die("out of memory", .{});
                    const got = switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| blk: {
                            if (size > 0 and (try c.slot()).tag == .none) self.portDiffers("reading a slot set to nothing into a buffer that isn't empty");
                            break :blk try c.readBytesObject(buffer);
                        },
                        else => unreachable,
                    };
                    self.checkBytes(op, got);
                },
                .read_stream => {
                    const buffer_size: usize = if (op.get("buffer_size")) |v| asInt(usize, v, "buffer_size") else 0;
                    const buffer = self.arena.alloc(u8, buffer_size) catch die("out of memory", .{});
                    switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| {
                            var cursor = c;
                            try self.checkStreamable(cursor);
                            var reader = try cursor.reader(buffer);
                            for (op.get("steps").?.array.items) |step| try self.streamStep(&reader, step.object);
                        },
                        else => unreachable,
                    }
                },
                .iterator => {
                    switch (self.anyCursor(cursorName(op))) {
                        inline .rw, .ro => |c| {
                            const iter = self.arena.create(@TypeOf(c).Iter) catch die("out of memory", .{});
                            iter.* = try self.makeIterator(c, op);
                            self.bind(op.get("as").?.string, wrapIterator(iter));
                        },
                        else => unreachable,
                    }
                },
                .next => {
                    const name = cursorName(op);
                    if (isKey(name, "root")) die("\"root\" is a cursor, not an iterator", .{});
                    const entry = self.entryFor(name);
                    const result: ?RO = switch (entry.binding) {
                        inline .iter_rw, .iter_ro => |iter| blk: {
                            self.checkIteratorUse(name, entry);
                            const next = try iter.next();
                            if (next != null and isPastEndOfList(iter)) self.portDiffers("an iterator giving an element past the end of an array list");
                            break :blk next;
                        },
                        else => die("\"{s}\" is not an iterator", .{name}),
                    };
                    checkNull(op, result == null);
                    if (op.get("as")) |as| self.bind(as.string, if (result) |c| .{ .ro = c } else .null_cursor);
                },
                .rank => {
                    const key = parseBytes(self.arena, op.get("key").?, "key");
                    const got = switch (self.anyCursor(cursorName(op))) {
                        .rw => |c| try (try DB.SortedMap(.read_only).init(c.readOnly())).rank(key),
                        .ro => |c| try (try DB.SortedMap(.read_only).init(c)).rank(key),
                        else => unreachable,
                    };
                    if (op.get("expect")) |v| {
                        const want = asInt(u64, v, "expect");
                        if (got != want) die("expected rank {d}, got {d}", .{ want, got });
                    }
                },
                .count => {
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

        fn readCommitId(store: *Store, committed_size: u64) !u64 {
            var reader = store.db.core.reader();
            try reader.seekTo(committed_size - TRAILER_SIZE + TRAILER_COMMIT_ID_OFFSET);
            var bytes: [8]u8 = undefined;
            try reader.interface.readSliceAll(&bytes);
            return std.mem.readInt(u64, &bytes, .big);
        }

        /// its committed size, or null if it can't say
        fn sizeOf(store: *Store) !?u64 {
            if (store.closed) return null;
            if (store.broken) return store.db.committedSize() catch null;
            return try store.db.committedSize();
        }

        fn execTopLevel(self: *Self, ops: []const Json, entries: []SidecarEntry) !void {
            for (ops, entries, 0..) |op, *entry, i| {
                const saved_loc = pushOpLoc(i);
                defer loc_len = saved_loc;

                self.top_index = i;
                self.compacted_into = null;
                self.execOp(op.object) catch |err| die("unexpected error {s}, which started at {s}", .{ @errorName(err), error_loc_buf[0..error_loc_len] });
                self.writes_after_op.append(self.arena, self.writes) catch die("out of memory", .{});

                // an error handled here was fatal to the op, so if it was a
                // transaction, it rolled back along with what its callbacks bound
                if (op.object.get("expect_error") != null) {
                    self.rolled_back.put(self.arena, i, {}) catch die("out of memory", .{});
                }

                // the size can change without a commit when a file is reopened, or
                // when bytes are applied to it, as those have commits of their own in them
                const op_name = op.object.get("op").?.string;
                const can_commit = !isKey(op_name, "reopen") and !isKey(op_name, "apply_replicated");

                var committed: ?*Store = null;
                var commit_id: ?u64 = null;
                for (self.stores.items) |store| {
                    const before = store.size_before;
                    const after = try sizeOf(store);
                    store.size_before = after;

                    if (can_commit and before != null and after != null and before.? != after.?) {
                        if (committed != null) die("one top-level op committed in both \"{s}\" and \"{s}\", which a sidecar has no way to say", .{ committed.?.name, store.name });
                        committed = store;
                        commit_id = try readCommitId(store, after.?);
                        removeTrailersFrom(store, before.?);
                        store.trailers.append(self.arena, .{
                            .position = after.? - TRAILER_SIZE,
                            .commit_id = commit_id.?,
                            .file_id = store.db.header.file_id,
                        }) catch die("out of memory", .{});
                    }

                    // a transaction either committed or was rolled back, so unless the
                    // file has been written to directly, or a sync stopped part way, nothing
                    // can be left past the committed bytes between top-level ops
                    if (after) |size| {
                        const length = try store.db.core.length();
                        if (length == size) {
                            store.may_have_leftovers = false;
                        } else if (!store.may_have_leftovers) {
                            die("{d} bytes are left past the committed size {d} of \"{s}\"", .{ length - size, size, store.name });
                        }
                    }
                }

                // a failed op that left something behind, in a transaction that committed
                if (self.note_port_changes) {
                    if (committed != null) {
                        for (self.failed_with_writes.items) |where| std.debug.print("change 16 {s}\n", .{where});
                    }
                    self.failed_with_writes.clearRetainingCapacity();
                }

                const described = committed orelse self.compacted_into orelse self.store;
                entry.* = .{
                    .committed_size = described.size_before,
                    .commit_id = commit_id,
                    .db = if (isKey(described.name, "main")) null else described.name,
                };
            }
        }

        fn runScript(opts: Options) !void {
            var validator: Self = .{ .arena = opts.arena, .validating = true, .allow_port_differences = opts.allow_port_differences };
            validator.validateOps(opts.ops);

            const io = opts.io;
            var self: Self = .{
                .arena = opts.arena,
                .gpa = opts.gpa,
                .io = io,
                .main_path = opts.out_path,
                .script_hash_id = opts.hash_id,
                .allow_port_differences = opts.allow_port_differences,
                .note_port_changes = opts.note_port_changes,
                .offset_map = std.AutoHashMap(u64, u64).init(opts.gpa),
            };
            defer self.offset_map.deinit();

            const main_store = opts.arena.create(Store) catch die("out of memory", .{});
            const buffer = opts.arena.create(Io.Writer.Allocating) catch die("out of memory", .{});
            buffer.* = Io.Writer.Allocating.init(opts.gpa);
            main_store.* = .{
                .name = "main",
                .db = undefined,
                .out = try Io.Dir.cwd().createFile(io, opts.out_path, .{ .read = true, .truncate = true }),
                .out_path = opts.out_path,
                .buffer = buffer,
            };
            main_store.db = try DB.init(io, initOpts(main_store, main_store.out, opts.file_id, opts.hash_id));
            main_store.size_before = try main_store.db.committedSize();
            const initial_size = main_store.size_before.?;
            self.store = main_store;
            try self.stores.append(opts.arena, main_store);

            const entries = try opts.arena.alloc(SidecarEntry, opts.ops.len);
            try self.execTopLevel(opts.ops, entries);

            for (self.stores.items) |store| {
                if (!store.closed) try store.db.core.flush();
                if (store.read_only_file) |file| file.close(io);
                if (kind == .memory) try store.out.writeStreamingAll(io, store.buffer.written());
            }

            try writeSidecar(opts, &self, initial_size, entries);

            for (self.stores.items) |store| {
                store.out.close(io);
                store.buffer.deinit();
            }
            if (self.offsets_file) |file| {
                file.close(io);
                Io.Dir.cwd().deleteFile(io, self.offsetsPath()) catch {};
            }
        }

        fn writeSidecar(opts: Options, self: *Self, initial_size: u64, entries: []const SidecarEntry) !void {
            var text = Io.Writer.Allocating.init(opts.gpa);
            defer text.deinit();
            const w = &text.writer;

            const file_size = try self.stores.items[0].out.length(opts.io);
            try w.print("{{\n  \"format\": \"{s}\",\n  \"file_id\": \"{x:0>16}\",\n  \"initial_size\": {d},\n  \"file_size\": {d},\n", .{
                SIDECAR_FORMAT,
                opts.file_id,
                initial_size,
                file_size,
            });
            if (self.stores.items.len > 1) try writeDatabases(opts, self, w);
            try w.writeAll("  \"ops\": [");
            for (entries, 0..) |entry, i| {
                try w.writeAll(if (i == 0) "\n    {" else ",\n    {");
                if (entry.db) |db| try w.print("\"db\": \"{s}\", ", .{db});
                if (entry.committed_size) |size| {
                    try w.print("\"committed_size\": {d}, ", .{size});
                } else {
                    try w.writeAll("\"committed_size\": null, ");
                }
                if (entry.commit_id) |id| {
                    try w.print("\"commit_id\": \"{x:0>16}\"}}", .{id});
                } else {
                    try w.writeAll("\"commit_id\": null}");
                }
            }
            try w.writeAll(if (entries.len == 0) "]\n}\n" else "\n  ]\n}\n");

            const path = try std.mem.concat(opts.arena, u8, &.{ opts.out_path, SIDECAR_SUFFIX });
            const file = try Io.Dir.cwd().createFile(opts.io, path, .{ .truncate = true });
            defer file.close(opts.io);
            try file.writeStreamingAll(opts.io, text.written());
        }

        /// each database's file, and the trailers in it, whose commit IDs and checksums are all that differ between runs
        fn writeDatabases(opts: Options, self: *Self, w: *Io.Writer) !void {
            try w.writeAll("  \"databases\": {");
            for (self.stores.items, 0..) |store, i| {
                const file_size = try store.out.length(opts.io);
                var file_id: u64 = 0;
                if (file_size >= 20) {
                    var bytes: [8]u8 = undefined;
                    _ = try store.out.readPositionalAll(opts.io, &bytes, 12);
                    file_id = std.mem.readInt(u64, &bytes, .big);
                }
                try w.print("{s}\n    \"{s}\": {{\"file_id\": \"{x:0>16}\", \"file_size\": {d}, \"trailers\": [", .{ if (i == 0) "" else ",", store.name, file_id, file_size });
                var first = true;
                for (store.trailers.items) |trailer| {
                    if (trailer.position >= file_size) continue;
                    try w.print("{s}\n      {{\"position\": {d}, \"commit_id\": \"{x:0>16}\", \"file_id\": \"{x:0>16}\"}}", .{ if (first) "" else ",", trailer.position, trailer.commit_id, trailer.file_id });
                    first = false;
                }
                try w.writeAll(if (first) "]}" else "\n    ]}");
            }
            try w.writeAll("\n  },\n");
        }
    };
}

/// null, or 4 bytes
fn parseHashId(arena: Allocator, v: Json) ?xitdb.HashId {
    if (v == .null) return null;
    const bytes = parseFixedBytes(4, arena, v, "hash_id");
    return xitdb.HashId.fromBytes(&bytes);
}

fn usage() noreturn {
    std.debug.print("usage: run <script> <out.db> [--kind buffered_file|file|memory] [--allow-port-differences] [--note-port-changes]\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) usage();
    var kind: xitdb.DatabaseKind = .buffered_file;
    var allow_port_differences = false;
    var note_port_changes = false;
    var arg_index: usize = 3;
    while (arg_index < args.len) : (arg_index += 1) {
        if (std.mem.eql(u8, args[arg_index], "--allow-port-differences")) {
            allow_port_differences = true;
        } else if (std.mem.eql(u8, args[arg_index], "--note-port-changes")) {
            note_port_changes = true;
        } else if (std.mem.eql(u8, args[arg_index], "--kind") and arg_index + 1 < args.len) {
            arg_index += 1;
            kind = std.meta.stringToEnum(xitdb.DatabaseKind, args[arg_index]) orelse usage();
        } else usage();
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
    if (script.get("description")) |description| _ = asString(description, "description");

    const hash_id = parseHashId(arena, required(script, "hash_id", "the script"));
    const file_id = parseHex64(arena, required(script, "file_id", "the script"), "file_id");
    const ops = asArray(required(script, "ops", "the script"), "ops");
    const hash_size = asInt(u16, required(script, "hash_size", "the script"), "hash_size");
    checkHashSize(hash_size);

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
                .allow_port_differences = allow_port_differences,
                .note_port_changes = note_port_changes,
            };
            switch (hash_size) {
                8 => try Runner(k, u64).runScript(common),
                20 => try Runner(k, u160).runScript(common),
                32 => try Runner(k, u256).runScript(common),
                64 => try Runner(k, u512).runScript(common),
                else => unreachable,
            }
        },
    }
}
