//! manifest <conformance commit> <zig commit> <zig version> <zig commits file> <script>...
//!
//! Prints fixtures/manifest.json. It is run from inside the fixtures folder with
//! the scripts as `valid/<name>.json` and `failing/<name>.json`, and lists what
//! each script needs, so that a second runner can say which scripts wait for
//! which of its milestones instead of failing on a part it doesn't have yet.
//! It also says which Zig commit each one comes from, which is the one given,
//! unless the zig commits file (tests/zig-commits.txt) says otherwise.
//!
//! The scripts have passed through `run`, so they're well-formed, and this only
//! fails on what it can't classify, or on a file it would name that isn't there.
//! The other databases of a script are the ones its sidecar lists, which are the
//! ones the run left.

const std = @import("std");

const Json = std.json.Value;
const Io = std.Io;

const MANIFEST_FORMAT = "xitdb-fixtures/1";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("manifest: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Features = struct {
    reopen: bool = false,
    recover: bool = false,
    raw_file: bool = false,
    read_only: bool = false,
    iterators: bool = false,
    rank: bool = false,
    byte_stream: bool = false,
    byte_buffers: bool = false,
    several_databases: bool = false,
    compaction: bool = false,
    disk_offsets: bool = false,
    replication: bool = false,
    inputs: bool = false,

    fn addOps(self: *Features, ops: Json) void {
        for (ops.array.items) |item| {
            const op = item.object;
            const name = op.get("op").?.string;
            if (std.mem.eql(u8, name, "close") or std.mem.eql(u8, name, "reopen")) self.reopen = true;
            if (std.mem.eql(u8, name, "recover")) self.recover = true;
            for ([_][]const u8{ "raw_append", "raw_write", "raw_load", "raw_truncate" }) |raw_op| {
                if (std.mem.eql(u8, name, raw_op)) self.raw_file = true;
            }
            if (std.mem.eql(u8, name, "raw_load")) self.inputs = true;
            if (op.get("read_only")) |v| {
                if (v == .bool and v.bool) self.read_only = true;
            }
            if (std.mem.eql(u8, name, "iterator") or std.mem.eql(u8, name, "next")) self.iterators = true;
            if (std.mem.eql(u8, name, "rank")) self.rank = true;
            if (std.mem.eql(u8, name, "read_stream")) self.byte_stream = true;
            if (std.mem.eql(u8, name, "read_bytes_into") or op.get("max_size") != null) self.byte_buffers = true;
            if (std.mem.eql(u8, name, "create_database") or std.mem.eql(u8, name, "use")) self.several_databases = true;
            if (std.mem.eql(u8, name, "compact")) {
                self.several_databases = true;
                self.compaction = true;
                if (std.mem.eql(u8, op.get("offset_map").?.string, "disk")) self.disk_offsets = true;
            }
            for ([_][]const u8{ "replica_state", "replication_start", "committed_size", "read_committed", "apply_replicated" }) |replication_op| {
                if (std.mem.eql(u8, name, replication_op)) self.replication = true;
            }
            // what's in a callback counts as well
            if (op.get("ctx")) |ctx| self.addOps(ctx.object.get("ops").?);
            if (op.get("path")) |path| {
                for (path.array.items) |part| {
                    if (part != .object) continue;
                    if (part.object.get("ctx")) |ctx| self.addOps(ctx.object.get("ops").?);
                }
            }
        }
    }

    fn print(self: Features, w: *Io.Writer) !void {
        var first = true;
        try w.writeAll("[");
        inline for (.{ "reopen", "recover", "raw_file", "read_only", "iterators", "rank", "byte_stream", "byte_buffers", "several_databases", "compaction", "disk_offsets", "replication", "inputs" }) |name| {
            if (@field(self, name)) {
                try w.writeAll(if (first) "\"" else ", \"");
                try w.writeAll(name);
                try w.writeAll("\"");
                first = false;
            }
        }
        try w.writeAll("]");
    }
};

/// the inputs a script loads with raw_load, each once, in the order it first loads them
fn inputsOf(arena: std.mem.Allocator, ops: Json) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (ops.array.items) |item| {
        const op = item.object;
        if (!std.mem.eql(u8, op.get("op").?.string, "raw_load")) continue;
        const input = op.get("input").?.string;
        var seen = false;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, input)) seen = true;
        }
        if (!seen) try names.append(arena, input);
    }
    return names.items;
}

/// the names of the other databases a script's run left, in the order it made them, from the
/// sidecar, which lists every database the run has a file for. it goes by what was written and
/// not by the script's text, as a compaction that fails can do so before it makes its target
/// or after, depending on the error and on whether it's the port's guard.
fn otherDatabases(io: Io, arena: std.mem.Allocator, sidecar_path: []const u8) ![]const []const u8 {
    const text = try Io.Dir.cwd().readFileAlloc(io, sidecar_path, arena, .unlimited);
    const sidecar = (try std.json.parseFromSliceLeaky(Json, arena, text, .{ .parse_numbers = false })).object;
    // a script with one database has no list
    const databases = sidecar.get("databases") orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    for (databases.object.keys()) |name| {
        if (std.mem.eql(u8, name, "main")) continue;
        try names.append(arena, name);
    }
    return names.items;
}

/// every path the manifest names is a file that's here, as a runner goes by them
fn mustExist(io: Io, path: []const u8) void {
    Io.Dir.cwd().access(io, path, .{}) catch fail("the manifest would name {s}, which isn't here", .{path});
}

const Collections = struct {
    array_list: bool = false,
    hash_map: bool = false,
    linked_array_list: bool = false,
    sorted_map: bool = false,

    fn addPart(self: *Collections, name: []const u8) void {
        // the linked list's prefix has to be looked for first, as it contains the other's
        if (std.mem.startsWith(u8, name, "linked_array_list_")) {
            self.linked_array_list = true;
        } else if (std.mem.startsWith(u8, name, "array_list_")) {
            self.array_list = true;
        } else if (std.mem.startsWith(u8, name, "hash_map_")) {
            self.hash_map = true;
        } else if (std.mem.startsWith(u8, name, "sorted_map_")) {
            self.sorted_map = true;
        } else if (!std.mem.eql(u8, name, "write") and !std.mem.eql(u8, name, "ctx")) {
            fail("path part \"{s}\" doesn't belong to any known collection", .{name});
        }
    }

    fn addOps(self: *Collections, ops: Json) void {
        for (ops.array.items) |op| {
            if (op.object.get("path")) |path| {
                for (path.array.items) |part| self.addPath(part);
            }
            if (op.object.get("ctx")) |ctx| self.addOps(ctx.object.get("ops").?);
        }
    }

    fn addPath(self: *Collections, part: Json) void {
        switch (part) {
            .string => |name| self.addPart(name),
            .object => |o| {
                const name = o.keys()[0];
                self.addPart(name);
                if (std.mem.eql(u8, name, "ctx")) self.addOps(o.values()[0].object.get("ops").?);
            },
            else => fail("a path part is neither a string nor an object", .{}),
        }
    }

    fn print(self: Collections, w: *Io.Writer) !void {
        var first = true;
        try w.writeAll("[");
        inline for (.{ "array_list", "hash_map", "linked_array_list", "sorted_map" }) |name| {
            if (@field(self, name)) {
                try w.writeAll(if (first) "\"" else ", \"");
                try w.writeAll(name);
                try w.writeAll("\"");
                first = false;
            }
        }
        try w.writeAll("]");
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 5) {
        std.debug.print("usage: manifest <conformance commit> <zig commit> <zig version> <zig commits file> <script>...\n", .{});
        std.process.exit(2);
    }

    var other_commits: std.StringHashMapUnmanaged([]const u8) = .empty;
    const commits_text = try Io.Dir.cwd().readFileAlloc(io, args[4], arena, .unlimited);
    var commit_lines = std.mem.splitScalar(u8, commits_text, '\n');
    while (commit_lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const fixture = fields.next() orelse continue;
        const commit = fields.next() orelse fail("\"{s}\" in {s} has no commit", .{ line, args[4] });
        try other_commits.put(arena, fixture, commit);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout.interface;

    try w.print("{{\n  \"format\": \"{s}\",\n  \"conformance_commit\": \"{s}\",\n  \"zig_commit\": \"{s}\",\n  \"zig_version\": \"{s}\",\n  \"fixtures\": [", .{
        MANIFEST_FORMAT,
        args[1],
        args[2],
        args[3],
    });

    for (args[5..], 0..) |path, i| {
        const passes = std.mem.startsWith(u8, path, "valid/");
        if (!passes and !std.mem.startsWith(u8, path, "failing/")) fail("{s} isn't in valid/ or failing/", .{path});
        const base = std.fs.path.basename(path);
        if (!std.mem.endsWith(u8, base, ".json")) fail("{s} isn't a .json file", .{path});
        const name = base[0 .. base.len - ".json".len];

        const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        const script = (try std.json.parseFromSliceLeaky(Json, arena, text, .{ .parse_numbers = false })).object;

        var collections: Collections = .{};
        collections.addOps(script.get("ops") orelse fail("{s} has no ops", .{path}));
        const format = script.get("format") orelse fail("{s} has no format", .{path});
        const hash_size = script.get("hash_size") orelse fail("{s} has no hash size", .{path});

        try w.writeAll(if (i == 0) "\n" else ",\n");
        try w.print("    {{\"name\": \"{s}\", \"outcome\": \"{s}\", \"format\": \"{s}\", \"hash_size\": {s}, \"zig_commit\": \"{s}\", \"script\": \"{s}\"", .{
            name,
            if (passes) "pass" else "fail",
            format.string,
            hash_size.number_string,
            other_commits.get(name) orelse args[2],
            path,
        });
        if (passes) {
            const db = try std.fmt.allocPrint(arena, "valid/{s}.db", .{name});
            const sidecar = try std.fmt.allocPrint(arena, "valid/{s}.db.sidecar.json", .{name});
            mustExist(io, db);
            mustExist(io, sidecar);
            try w.print(", \"db\": \"{s}\", \"sidecar\": \"{s}\"", .{ db, sidecar });
            const others = try otherDatabases(io, arena, sidecar);
            if (others.len > 0) {
                try w.writeAll(", \"other_databases\": {");
                for (others, 0..) |other, other_index| {
                    const other_db = try std.fmt.allocPrint(arena, "valid/{s}.{s}.db", .{ name, other });
                    mustExist(io, other_db);
                    try w.print("{s}\"{s}\": \"{s}\"", .{ if (other_index == 0) "" else ", ", other, other_db });
                }
                try w.writeAll("}");
            }
        }
        const inputs = try inputsOf(arena, script.get("ops").?);
        if (inputs.len > 0) {
            try w.writeAll(", \"inputs\": [");
            for (inputs, 0..) |input, input_index| {
                const input_path = try std.fmt.allocPrint(arena, "inputs/{s}.db", .{input});
                mustExist(io, input_path);
                try w.print("{s}\"{s}\"", .{ if (input_index == 0) "" else ", ", input_path });
            }
            try w.writeAll("]");
        }
        try w.writeAll(", \"collections\": ");
        try collections.print(w);
        var features: Features = .{};
        features.addOps(script.get("ops").?);
        try w.writeAll(", \"features\": ");
        try features.print(w);
        try w.writeAll("}");
    }
    try w.writeAll("\n  ]\n}\n");
    try w.flush();
}
