//! manifest <conformance commit> <zig commit> <zig version> <script>...
//!
//! Prints fixtures/manifest.json. It is run from inside the fixtures folder with
//! the scripts as `valid/<name>.json` and `failing/<name>.json`, and lists what
//! each script needs, so that a second runner can say which scripts wait for
//! which of its milestones instead of failing on a part it doesn't have yet.
//!
//! The scripts have passed through `run`, so they're well-formed, and this only
//! fails on what it can't classify.

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
    raw_file: bool = false,
    read_only: bool = false,

    fn addOp(self: *Features, op: std.json.ObjectMap) void {
        const name = op.get("op").?.string;
        if (std.mem.eql(u8, name, "close") or std.mem.eql(u8, name, "reopen")) self.reopen = true;
        if (std.mem.eql(u8, name, "raw_append") or std.mem.eql(u8, name, "raw_write")) self.raw_file = true;
        if (op.get("read_only")) |v| {
            if (v == .bool and v.bool) self.read_only = true;
        }
    }

    fn print(self: Features, w: *Io.Writer) !void {
        var first = true;
        try w.writeAll("[");
        inline for (.{ "reopen", "raw_file", "read_only" }) |name| {
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
    if (args.len < 4) {
        std.debug.print("usage: manifest <conformance commit> <zig commit> <zig version> <script>...\n", .{});
        std.process.exit(2);
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

    for (args[4..], 0..) |path, i| {
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
        try w.print("    {{\"name\": \"{s}\", \"outcome\": \"{s}\", \"format\": \"{s}\", \"hash_size\": {s}, \"script\": \"{s}\"", .{
            name,
            if (passes) "pass" else "fail",
            format.string,
            hash_size.number_string,
            path,
        });
        if (passes) {
            try w.print(", \"db\": \"valid/{s}.db\", \"sidecar\": \"valid/{s}.db.sidecar.json\"", .{ name, name });
        }
        try w.writeAll(", \"collections\": ");
        try collections.print(w);
        var features: Features = .{};
        for (script.get("ops").?.array.items) |op| features.addOp(op.object);
        try w.writeAll(", \"features\": ");
        try features.print(w);
        try w.writeAll("}");
    }
    try w.writeAll("\n  ]\n}\n");
    try w.flush();
}
