# Script format, version 1

A script is a JSON document describing a sequence of calls on an xitdb database, at the level of Zig's path
API. `src/run.zig` executes a script on the Zig implementation and records the resulting file. A second runner
executes the same script on another implementation, feeding it the commit IDs Zig chose, and must then produce
the same file, byte for byte.

**Each op is one call.** A runner looks up the names an op refers to, builds the arguments, makes the call and
binds the result. It adds no checks and no recovery of its own: if the engine does something odd, the script
is there to pin it down. Section 11 lists the oddities a runner might be tempted to fix.

Every script a second runner is given has been accepted by `run`, which checks all of a script's shape before
running any of it ([section 10](#10-valid-scripts-and-script-failures)). So the rules below on how things are
written are promises to a second runner, and it needn't enforce them.

`scripts/` holds the hand-written scripts, and between them `scripts/` and `tests/valid/` use every op, path part, form
of value and error name in this document, which `src/coverage.zig` checks in the gate. The file format itself is
described in `../director/research/file-format.md`.

## 1. The document

```json
{
  "format": "xitdb-script/1",
  "description": "free text",
  "hash_size": 20,
  "hash_id": "sha1",
  "file_id": "0011223344556677",
  "ops": []
}
```

| Field | Required | Meaning |
|---|---|---|
| `format` | yes | exactly `"xitdb-script/1"` |
| `description` | no | a string, which is ignored |
| `hash_size` | yes | size of a hash in bytes, written to header bytes 6–7: 8, 20, 32 or 64 |
| `hash_id` | yes | [bytes](#bytes), exactly 4, written to header bytes 8–11; or `null`, for 4 zero bytes |
| `file_id` | yes | exactly 16 lowercase hex digits, the 8 bytes of header bytes 12–19 in order |
| `ops` | yes | the [ops](#5-ops), run in order |

The runner starts with an empty file, creates a new database with these parameters, and runs the ops. Creating
the database commits an empty root with commit ID 0, which gives a new database of 57 bytes in format version 2.

**The file format is version 2** since the original's `bdaa55e`. After the 20-byte database header come four bytes of
padding, which nothing reads or writes, and then the root header, which is the committed size alone, 8 bytes at
offset 24. Committed data starts at 32, and a new database's trailer is at 32 to 56. `file-format.md` describes
version 1, which the original still opens and keeps as version 1, and which nothing creates any more: there the
root header is a copy of the root slot at 20 to 28, which the original no longer reads or updates, and the committed
size at 29, and data starts at 37, so a new database is 62 bytes. A script can start from a version 1 file with
`raw_load` ([section 5](#5-ops)).

Fields may be in any order, and a field never appears twice. Every op may have a `note` field, a string that is
ignored.

**A runner must fail on a `format` it doesn't know, and when it reaches a field, op, path part or tag it doesn't
know.** Ignoring one would silently weaken the check.

## 2. Values

### Integers

A JSON integer literal, with no fraction or exponent, parsed exactly over its whole range:

- `0` to 2⁶⁴−1 for an unsigned value: `uint`, `size`, `offset`, a slot's `value`, and the `expect` of `read_uint`
  and `count`.
- −2⁶³ to 2⁶³−1 for a signed one: `int`, indexes, and the `expect` of `read_int`.

`-0` isn't used. `seek` is unsigned and goes up to 2²⁴, which isn't a limit of the engine: it keeps a script
runnable on every storage kind.

Don't parse through a double. Swift's `JSONDecoder` and `JSONSerialization` were both checked to be exact at both
ends of these ranges, on macOS 27, and so was Zig's `std.json` with `parse_numbers = false`.

Indexes are `i65` in Zig, but scripts only go as far as `i64`.

### Bytes

Either form, wherever this document says *bytes*:

- a JSON string: the UTF-8 encoding of the string after JSON unescaping. Nothing is normalized: `"é"` is
  the 3 bytes `65 cc 81`, not the 2 bytes of `é`. In Swift, take `.utf8` of the string, and compare bytes rather
  than `String`s, because `String` equality treats those two as equal. U+FEFF isn't used in this form, because
  Swift's `JSONSerialization` drops one from the start of a string: those bytes are written as hex.
- `{"hex": "610062"}`: an even number of lowercase hex digits, the bytes in order. The empty string is allowed.

Whether a value ends up inline in its slot (`short_bytes`) or in a record of its own (`bytes`) is the engine's
decision, based on the value's bytes and whether it has a format tag. The only ways a script can ask for either are
that `writer` always produces `bytes`, and a literal slot can be `short_bytes`.

### Format tags

[Bytes](#bytes), exactly 2. `"bi"` and `{"hex": "6269"}` are the same tag. To have no tag, leave the field out:
`null` isn't a format tag, except in `expect_format_tag`. `{"hex": "0000"}` is a tag like any other, and sets the
slot's `full` flag.

### Hashes

Exactly one of:

- `{"hex": "..."}`: exactly `2 * hash_size` lowercase hex digits.
- `{"sha1": BYTES}`: the SHA-1 digest of those [bytes](#bytes). Only used when `hash_size` is 20.

The digits, or the digest, are **the hash's bytes in the order they appear on disk**, at the start of the key-value
pair. Zig reads them into its `HashInt` as a big-endian integer (`std.mem.readInt(HashInt, &hash, .big)`) and
writes them back the same way. A runner that passes hashes as bytes passes them along unchanged.

So the trie is walked from the **end** of the written hash, low nibble first. `{"sha1": "foo"}` is
`0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33`, whose last byte is `33`, so level 0 uses slot 3, level 1 uses slot
3, and level 2 uses slot `a`, from the `8a` before it.

### Floats

Exactly 16 lowercase hex digits: the IEEE 754 bit pattern, most significant first, which is also what's on disk.
`"400921fb54442d18"` is π. There is no decimal form, so nothing is rounded and NaN payloads survive. Compare
floats by their bits.

### Slots

Write data and `linked_array_list_concat` take a slot, which is one of:

- `{"var": NAME}`: the slot [bound](#4-names) to `NAME`, which may hold null.
- `{"tag": NAME, "value": 77, "full": false}`: a literal slot. `tag` is `none`, `short_bytes`, `uint`, `int` or
  `float`, the tags whose value isn't a file offset. `value` defaults to 0 and `full` to false. It is passed as it
  is, whatever it means.
- `null`: no slot. Only write data takes one, being `?Slot` in Zig. A `{"var": NAME}` that holds null counts as
  `null`, and that is a script failure in `linked_array_list_concat`.

A slot with the tag `index`, `kv_pair` or `sorted_kv_pair` is part of a collection's structure rather than a value.
It can be read into a name, but writing it is an undefined use ([section 10](#10-valid-scripts-and-script-failures)). With
`--port`, the port refuses it ([section 11](#what-the-port-does)).

The tag names used elsewhere, in `expect`, are those of the `Tag` enum: `none`, `index`, `array_list`,
`linked_array_list`, `hash_map`, `kv_pair`, `bytes`, `short_bytes`, `uint`, `int`, `float`, `hash_set`,
`counted_hash_map`, `counted_hash_set`, `sorted_map`, `sorted_set`, `sorted_kv_pair`.

### Write data

`WriteableData`, with exactly one field. It's used by the `write` path part, and by the `write` and
`write_if_empty` ops.

| JSON | Zig |
|---|---|
| `{"slot": SLOT}` | `.slot` |
| `{"uint": 18446744073709551615}` | `.uint` |
| `{"int": -1}` | `.int` |
| `{"float": "400921fb54442d18"}` | `.float` |
| `{"bytes": BYTES}` | `.bytes` |
| `{"bytes_object": {"value": BYTES, "format_tag": TAG}}` | `.bytes_object`. `format_tag` is optional |

## 3. Path parts

A path is a JSON array, and each element is one `PathPart`. A part with no payload is a string; any other is an
object with exactly one field.

| JSON | Zig |
|---|---|
| `"array_list_init"` | `.array_list_init` |
| `{"array_list_get": -1}` | `.array_list_get` |
| `"array_list_append"` | `.array_list_append` |
| `{"array_list_slice": {"size": 2}}` | `.array_list_slice` |
| `"linked_array_list_init"` | `.linked_array_list_init` |
| `{"linked_array_list_get": -1}` | `.linked_array_list_get` |
| `"linked_array_list_append"` | `.linked_array_list_append` |
| `{"linked_array_list_slice": {"offset": 1, "size": 3}}` | `.linked_array_list_slice` |
| `{"linked_array_list_concat": {"list": SLOT}}` | `.linked_array_list_concat` |
| `{"linked_array_list_insert": 1}` | `.linked_array_list_insert` |
| `{"linked_array_list_remove": 0}` | `.linked_array_list_remove` |
| `{"hash_map_init": {"counted": true, "set": false}}` | `.hash_map_init`. Both fields are optional and default to false |
| `{"hash_map_get": {"value": HASH}}` | `.hash_map_get`, with exactly one of `kv_pair`, `key`, `value` |
| `{"hash_map_remove": HASH}` | `.hash_map_remove` |
| `{"sorted_map_init": {"set": true}}` | `.sorted_map_init`. `set` is optional and defaults to false |
| `{"sorted_map_get": {"value": BYTES}}` | `.sorted_map_get`, with exactly one of `kv_pair`, `key`, `value` |
| `{"sorted_map_get_index": 0}` | `.sorted_map_get_index` |
| `{"sorted_map_remove": BYTES}` | `.sorted_map_remove` |
| `{"write": DATA}` | `.write` |
| `{"ctx": {"as": NAME, "ops": [...]}}` | `.ctx`: a [callback](#6-callbacks) |

The runner passes the path as written. Whether it makes sense is the engine's business: `[{"ctx": ...}, {"write":
...}]` is a fine thing to write, and it fails with `PathPartMustBeAtEnd`.

Everything in a path, including `{"var": NAME}`, is evaluated once, before the call starts. The exception is the ops
inside a `ctx`, which are evaluated when they run.

## 4. Names

A script has one table of names, with no scopes. A name is made of ASCII letters, digits and underscores, and
doesn't start with a digit. It stays bound for the rest of the script, until something binds it again, including
after the callback or transaction that bound it has ended. Each name holds one of:

- a read-write cursor,
- a read-only cursor,
- a slot, or null, from a slot-reading op,
- a null cursor, from a `read_path` or a `next` that found nothing,
- an iterator,
- from the replication ops, a number, a replica's state, or committed bytes.

`root` is reserved and can't be bound. Each use of it means a new `rootCursor()` of the current database
([several databases](#several-databases)), and it can only be used as a cursor.

These are script failures ([section 10](#10-valid-scripts-and-script-failures)): using a name that isn't bound,
using a null cursor for anything, using a slot as a cursor or a cursor as a slot, using an iterator as anything but an
iterator, using what the replication ops bind as anything but what it is, and using a read-only cursor where a
read-write one is needed, as those methods don't exist on read-only cursors in Zig.

### What a cursor holds

**Cursors are values.** Binding one copies it, and two names never alias. A cursor holds a position, a **snapshot**
of the slot at that position, and a **freeze point**, and is only updated by what's done through that name.

The snapshot:

- `write`, `write_if_empty` and `writer` update the cursor they are called on, as Zig's take `*Cursor`.
- `write_path` does not change the cursor it is called on. Its result is a new cursor, bound by `as`.
- `slot`, `count`, `write_if_empty` and the `read_*` ops go by the snapshot, however stale it is, as do
  `read_path` and `read_path_slot`. So `write_if_empty` on a cursor whose snapshot is empty overwrites a value it
  can't see. On the fixes branch, `fix-findings-v2` at `bd6abc3`, it goes by the slot as it is now instead
  ([section 11](#what-a-later-zig-changes)).
- `write_path` starts by reading the slot at the cursor's position again, if it has one, so its result sees the
  present.

The freeze point, which is the `frozen_at` of a Zig cursor, is a file position. Writes through the cursor copy
anything written before it, instead of changing it in place, even if the current transaction wrote it
(`isOld`, `lib.zig:840`). A cursor with no freeze point copies only what's older than the transaction.

- `freeze` sets it to the current end of the file, on the cursor it's called on.
- The result of `write_path`, the cursors from `read_key_value_pair` and the cursor given to a callback take it from
  the cursor they were made through. A cursor from `run_context` starts with none.
- Cursors from `read_path` and `read_only` don't have one. They're read-only, so it wouldn't matter.
- It doesn't come back out of a callback ([section 6](#6-callbacks)).

**A root cursor is the exception**, read-write or read-only: everything it does reads the root from the last commit,
so it's never stale. That means it doesn't see a transaction in progress either: `count` on a root list inside a
callback gives the count from before the transaction. `root` is one, and so is `read_only` on one, but `read_path` on
one isn't, even with an empty path: it gives a cursor pinned to that commit.

### What a kept cursor can do

`write_path` returns a root cursor if its path ended at the root, as a lone `hash_map_init` does, and every write
through that cursor is a transaction of its own. Any other cursor from a finished transaction can still be read.
Writing through it fails with `ExpectedTxStart` between transactions, and works during a later transaction, where it
overwrites committed bytes ([section 11](#11-behaviour-a-runner-must-not-fix)).

Using a cursor or a slot from a transaction that was rolled back is an undefined use
([section 10](#10-valid-scripts-and-script-failures)). With `--port`, the reads and writes through one are refused
([section 11](#what-the-port-does)).

## 5. Ops

Every op is an object with an `op` field. An op can have `note`, and all of them except `fail`, `create_database`, `use`,
`close` and the raw ops below for closing and reopening can have `expect_error` ([section 7](#7-errors)). A name in `on` must hold a cursor, and optional fields marked `?` can be
left out. `expect` and its relatives are checked after the call and are described below the table.

| `op` | Other fields | Call | Result |
|---|---|---|---|
| `write_path` | `on`, `path`, `as?` | `on.writePath(path)` | `as`: the returned cursor |
| `write` | `on`, `data` | `on.write(data)` | updates `on` |
| `write_if_empty` | `on`, `data` | `on.writeIfEmpty(data)` | updates `on`, if it wrote |
| `writer` | `on`, `format_tag?`, `steps` | see below | updates `on` |
| `freeze` | `on` | `on.freeze()` | updates `on` |
| `db_freeze` | | `db.freeze()` | |
| `run_context` | `ctx` | `db.runContext(ctx)`, `ctx` being `{"as": NAME, "ops": [...]}` | |
| `fail` | | `return error.ScriptAbort`. Only used in a callback | |
| `read_path` | `on`, `path`, `as?`, `expect_null?` | `on.readPath(path)` | `as`: a read-only cursor, or a null cursor |
| `read_path_slot` | `on`, `path`, `as?`, `expect_null?`, `expect?` | `on.readPathSlot(path)` | `as`: a slot, or null |
| `slot` | `on`, `as?`, `expect?` | `on.slot()` | `as`: a slot |
| `read_only` | `on`, `as` | `on.readOnly()` | `as`: a read-only cursor |
| `read_key_value_pair` | `on`, `key_as?`, `value_as?`, `expect_hash?` | `on.readKeyValuePair()` | `key_as`, `value_as`: two different names, for cursors of the same kind as `on` |
| `read_uint` | `on`, `expect?` | `on.readUint()` | |
| `read_int` | `on`, `expect?` | `on.readInt()` | |
| `read_float` | `on`, `expect?` | `on.readFloat()` | |
| `read_bytes` | `on`, `max_size?`, `expect?`, `expect_format_tag?` | `on.readBytesObjectAlloc(allocator, max_size)`, with `null` if `max_size` is left out | |
| `read_bytes_into` | `on`, `size`, `expect?`, `expect_format_tag?` | `on.readBytesObject(buffer)`, with a buffer of `size` bytes | |
| `read_stream` | `on`, `buffer_size?`, `steps` | see below | |
| `count` | `on`, `expect?` | `on.count()` | |
| `iterator` | `on`, `from_index?` or `from_key?`, `as` | see below | `as`: an iterator |
| `next` | `on`, `as?`, `expect_null?` | `on.next()`, `on` being an iterator | `as`: a read-only cursor, or a null cursor |
| `rank` | `on`, `key`, `expect?` | the `rank` of a `SortedMap(.read_only)` or `SortedSet(.read_only)` on the cursor. It's the number of keys less than `key`, which needn't be there. It's 0 on a slot with nothing in it, and it raises `UnexpectedTag` on a slot that isn't a sorted map or set, going by the tag alone | |

`write_path`, `write`, `write_if_empty`, `writer`, `freeze` and `read_only` need a read-write cursor. The others
take either kind. `size`, `buffer_size` and the sizes in `read_stream`'s steps go up to 2²⁴. These reads change no
bytes.

`read_bytes` and `read_bytes_into` raise `StreamTooLong` when the value is longer than `max_size` or `size`, and a
format tag doesn't count towards that. A slot with nothing in it fits in any `max_size`, and in a `size` of 0.

**`writer`** is one op from opening the writer to finishing it, so nothing else can happen in between:

```zig
var w = try on.writer(&.{});
w.format_tag = format_tag; // if given
// for each step, in order:
//   {"write": BYTES}   try w.interface.writeAll(bytes);
//   {"seek": 3}        try w.seekTo(3);
try w.finish();
```

`steps` can be empty, which writes a zero-length `bytes` record: unlike `write`, `writer` never produces
`short_bytes`, however few bytes there are.

**`read_stream`** is one op from opening the reader to the last step, as `writer` is:

```zig
var r = try on.reader(buffer); // of buffer_size bytes, which is 0 if left out
// for each step, in order:
//   {"read": 10, "expect?": BYTES}      r.interface.readSliceShort(dest[0..10]), which stops early at the end of the value
//   {"read_all": 10, "expect?": BYTES}  r.interface.readSliceAll(dest[0..10]), which raises EndOfStream if there are fewer
//   {"seek": 3}                         r.seekTo(3), which can go past the end, as far as 2^64 - 1
//   {"position": 3}                     r.logicalPos() must be 3, or it's a script failure
```

`expect` is compared with what the read gave, so `{"read": 10, "expect": "abc"}` passes for a value with three bytes
left. A format tag isn't part of a value's stream. A failed step ends the op, as there's no way to go on with the same
reader afterwards. What a stream gives doesn't depend on `buffer_size`, so a runner whose reader has no such thing
ignores it. `tests/valid/reads-stream.json` holds Zig to that with several sizes.

A stream raises `UnexpectedTag` on anything but a byte value. Three uses of it are for the port to correct
([section 10](#what-the-port-corrects)), and a valid script doesn't contain them: on a slot with nothing in it, and on a
`short_bytes` slot from a cursor with no position, or whose slot has since been overwritten.

**`iterator`** makes an iterator on `on`:

| Field | Call | On |
|---|---|---|
| neither | `on.iterator()` | any collection |
| `from_index` | `ArrayList.iteratorFrom`, `LinkedArrayList.iteratorFrom`, or `SortedMap.iteratorFromIndex` and the set's | array lists, linked array lists, sorted maps and sets. It counts from the end if negative, and gives nothing if it's out of range |
| `from_key` | `SortedMap.iteratorFrom` and the set's | sorted maps and sets. It starts at the first key that isn't less than this one |

Any of them on a slot with nothing in it gives an iterator that gives nothing. That includes `from_key`, so a runner
needs that much of it before it has sorted maps: `reads-iterators` does it on an empty root. On a slot of any other kind
they raise `UnexpectedTag`. Which call a runner makes depends on the tag it finds, and the wrappers add only a check of the tag,
which raises the same error.

**Unlike a cursor, an iterator isn't a value.** There's one per `iterator` op, and `next` moves it, however it's reached.
What it gives is always a read-only cursor. It's the entry itself for a map, a `kv_pair` or `sorted_kv_pair` that needs
`read_key_value_pair`. In a sorted set it's a `short_bytes` or `bytes` slot, which is the key. After the last one, `next`
goes on giving null. A hash map's order is its trie's, by the lowest nibble of the hash first.

An iterator goes by the cursor's snapshot, or the last commit for a root cursor, like the reads in
[section 4](#what-a-cursor-holds). One kept across a commit goes on seeing what it saw, since committed data isn't
changed. One made during a transaction mustn't be used after a write in that same transaction, which is an undefined
use ([section 10](#an-undefined-use)).

**Closing and reopening** model a process stopping and another one starting, with whatever a crash did to the file in
between. These ops only appear at the top level, and only `reopen` can have `expect_error`.

| `op` | Other fields | What it does |
|---|---|---|
| `close` | | Ends the use of the database. Commits are already in the file, so nothing happens to it. **Every name becomes unbound** |
| `reopen` | `read_only?`, `hash_size?`, `file_id?`, `hash_id?` | `Database.init` on the file as it is, given `file_id` and `hash_id` as the options of the same names, or `null` for what's left out |
| `raw_append` | `bytes` | Writes the bytes at the end of the file |
| `raw_write` | `offset`, `bytes` | Writes the bytes at `offset`, which goes up to 2²⁴, leaving zeros if that's past the end |
| `raw_load` | `input` | Replaces the whole file with the bytes of an input, below |
| `raw_truncate` | `length` | Cuts the file off at `length`, which can't be past its end |

While the database is closed, only the raw ops and `reopen` can run, and the raw ops can't run while it's open. So can
`recover`, which is only in what the port does ([section 11](#what-the-port-does)). Anything else is a script failure. The
raw ops write straight to storage, past the engine.

**An input** is a file a script starts from, named by lowercase letters, digits and hyphens. The fixtures have it as
`inputs/<input>.db`, and `run` looks for it in `tests/inputs/`, or the folder given with `--inputs`. `raw_load` puts it in
place of the current database's file, which then has to be opened with `reopen`, and it can only replace a database that
hasn't committed in the script yet, which a `reopen` that creates the database again doesn't count as. It's how a script
gets a version 1 file: the inputs called `v1-*` were written by the original at `6b93af1`, and `tests/inputs/README.md`
says what's in each. It's also how a script gets a file only an undefined use makes: the inputs called `sorted-*` and
`linked-*` are clones the freeze hazard left with a header that disagrees with its tree (section 10), each made once on the
original at `89da8e7` by its maker in `tests/undefined/`, and a valid script only reads them. The manifest lists each
script's inputs as `inputs`.

**`file_id` and `hash_id` on `reopen`** only matter when `Database.init` creates the database, which since `92a926e` it
does for a file without a first commit that's no bigger than a new database: one cut off during its creation. It
creates it as a new database of version 2, with the file ID given, or a random one when there's none, and the hash ID
given, or 4 zero bytes, never the cut file's own. As a random file ID would be a draw that no sidecar records, a
script that opens such a file gives `file_id`. A file shorter than the 20 bytes of its database header raises
`EndOfStream`.

**A database without a first commit** is one whose root header's committed size is 0, which is how a copy from 0
leaves it until all its bytes have arrived. If it's bigger than a new database, `reopen` opens it as it is, as a full
copy that didn't finish, for the next sync at 0 to replace. Then `committed_size` raises `InvalidDatabase`, and so does
every read and write through the root, a root cursor's `slot` included. `replica_state` gives zero and zero, so
`replication_start` gives 0 for it.

`reopen` states a hash size: the script's, or `hash_size` if given, which is 8, 20, 32 or 64. It never takes the size
from the file, so a header that says otherwise is `InvalidHashSize`. If `reopen` fails, the database stays closed.
With `read_only: true` the file is opened read-only, which the `memory` storage kind doesn't have: `run --kind memory`
rejects such a script, and the manifest lists it as needing `read_only`.

What happens to **bytes past the committed size**:

| | They |
|---|---|
| `reopen`, on any file | stay |
| reads, and a write path with an empty path | stay |
| one init part matching the root's tag ([section 8](#8-transactions-and-commit-ids)) | are truncated, with no commit |
| any transaction, whether it commits or fails | are truncated |

On a **read-only file**, reads work. A transaction fails with `WriteFailed` and leaves the file as it was. A free init
still works, and truncating silently does nothing, so bytes past the committed size stay. For the same reason a file
cut off during its creation, opened read-only, isn't created again: it opens as a database without a first commit and
stays as it was, and its `committed_size` raises `EndOfStream` if the file is too short to hold one.

### Several databases

A script starts with one database, called `main`, and that's the **current** one. These ops only appear at the top
level:

| `op` | Other fields | What it does |
|---|---|---|
| `create_database` | `name`, `file_id`, `hash_id?` | `Database.init` on a new, empty file, with that file ID. Its hash ID is `hash_id` if given, which can be `null`, and otherwise the script's. It doesn't become the current one |
| `use` | `name` | Makes that database the current one |

Every database in a script has the script's hash size. A name that's already a database can't be used for a new one,
and `main` already is one. A name that isn't a database can't be used. Either of those is a script failure. Names of
databases have nothing to do with the names in [section 4](#4-names).

**The current database** is what `root` means, and what every op with no `on` acts on: `run_context`, `db_freeze`,
`close`, `reopen`, the raw ops, `compact`, and the replication ops. A callback's `db_freeze` is the
current database's too.

**A cursor stays with the database it came from**, and so does an iterator. Using one while another database is current
is allowed, and acts on the one it came from, for reading and for writing. A root cursor kept with an empty `write_path`
commits in its own database whichever is current, and a write through a cursor from a finished transaction raises
`ExpectedTxStart`, unless its own database has a transaction going. `several-databases` pins all of this. The exceptions
are that `close` unbinds every name, whichever database it came from, and that while the current database is closed,
only `use`, `create_database`, `reopen` and the raw ops can run.

`run` fails on one top-level op that commits in two databases, which takes a root cursor from one being written to in a
callback of the other, because a sidecar has one entry per op. Scripts don't do this.

### Compaction

| `op` | Other fields | What it does |
|---|---|---|
| `compact` | `into`, `file_id?`, `hash_id?`, `offset_map`, and only at the top level | `current.compact(kind, opts, &map)`, leaving the target's file as the database called `into`. The current database stays the current one |

What `into` names decides what's needed. `compact-targets` has all three cases:

| `into` | `file_id` | The target |
|---|---|---|
| a name that isn't a database yet | required, or it's a script failure, as Zig would pick a random one | a new one, which goes on being a database of the script. Its hash ID is `hash_id` if given and not `null`, and otherwise the source's |
| a database that exists and has an empty root, such as one from `create_database` that was never written to | not allowed, or it's a script failure | that one, keeping its own file ID and hash ID. A cursor kept from it goes on working |
| a database with anything else in its root, including the current one | not allowed, or it's a script failure | raises `TargetNotEmpty` and is left as it was |

`offset_map` says what remembers where things went while it's copying. It doesn't change what's written, and
`check.sh` runs every script that uses one with the other in its place, to hold it to that:

- `"memory"` is an `std.AutoHashMap(u64, u64)`, which `compact` clears at its start.
- `"disk"` is what `test.zig` calls a disk-backed offsets map: a hash map with 8-byte hashes, in a private database with
  its own file, in one transaction that lasts for the whole compaction. `compact` resets it at its start, and the Zig
  runner uses one for the whole script, so that a compaction has to forget the last one. A runner whose engine takes any object with
  `reset`, `get` and `put` should use it, and one whose engine has no such thing can treat it like `"memory"`, and has
  nothing to compare, as the private database is never part of an expected file. The manifest lists these scripts as
  needing `disk_offsets`.

The target always has the same storage kind as the source here. Zig allows them to differ, and the bytes don't depend on
it, as `--kind` shows for each kind alone, but no script mixes them.

What it writes depends on the source's root. It commits once in the target, or not at all if there's nothing to write:

| Root | The target |
|---|---|
| empty, with `full` not set | no commit |
| an array list, whose last moment is empty or which has no moments | no commit. So a list with no moments gives an empty root, and not an empty list ([section 11](#11-behaviour-a-runner-must-not-fix)). The port refuses it with `EmptyLastMoment` ([section 11](#what-the-port-does)) |
| any other array list | a new array list with only its last moment |
| anything else, including one set to nothing | written whole |

### Replication

These only appear at the top level, and act on the current database. A number is an integer or `{"var": NAME}`, a name
that holds one.

| `op` | Other fields | Call | Result |
|---|---|---|---|
| `replica_state` | `as` | `current.replicaState()` | `as`: a replica's state |
| `replication_start` | `state`, `as?`, `expect?` | `current.replicationStart(state)`, `state` being a name holding a replica's state, which can come from any database | `as`: a number |
| `committed_size` | `as?`, `expect?` | `current.committedSize()` | `as`: a number |
| `read_committed` | `start`, `end`, `as`, `expect_same?` | `current.readCommitted(start, end, writer)`, with both being numbers, and writing to memory | `as`: committed bytes |
| `apply_replicated` | `start`, `bytes`, `short_by?`, `stream_short_by?` | `current.applyReplicated(start, reader, len)`, with `start` a number, `bytes` a name holding committed bytes, a reader over them as `short_by` leaves them, and `len` their length as it leaves them. `stream_short_by` then leaves that many more off the reader only | |

`expect` on `replication_start` and `committed_size` is a number. `expect_same` is a name holding committed bytes, and
what was read must be the same bytes. An expected file only says how a database ended up, so this is what scripts use to
say how each sync left a replica: its committed bytes are the source's, and the source's are in its expected file.
`short_by` leaves that many bytes off the end of `bytes`, which is the sync that was interrupted, and is how an append
comes to fail. `stream_short_by` leaves that many off what the reader gives, while `len` stays what `short_by` left, which is a
sync whose stream stopped part way, so the call reads past the end of what it's given and raises `EndOfStream`. A copy at 0
reads the database header first, and since `92a926e` then writes the data in blocks of 4096 bytes, each once it has all of it,
so one whose stream stops leaves the database header, a root header of zeros, and the blocks that arrived whole
(`replicate-copy-cut-short`).

What's applied must be applied where it was read from: `run` fails on a `start` other than the one it was read with, if
the start is one that gets as far as writing. Those are 0, and the database's committed size. Any other raises
`InvalidRange`, and changes nothing.

A sync is several ops, and `replicate-history` shows them. A failed append leaves the database as it was, with what it
wrote past the committed bytes, and the next one writes over that. A sync at 0 is another thing. Since `92a926e` it
reads and checks the database header that comes first in the bytes, raising `InvalidRange` and changing nothing if there
are fewer bytes than that header and the root header after it. Then it empties the file and writes that database header
with a root header of zeros, skips the root header that came with the bytes, and copies the rest, and only once all of
it has arrived does it write the committed size. So one that fails leaves a database without a first commit
([closing and reopening](#5-ops)), until a sync at 0 succeeds. `replicate-failed-first-sync` has this. That's a copy in
place, which is what every storage kind of the original does. The port's file storages replace the file on a full copy
instead, which leaves the database as it was after a failed one, and the manifest marks the scripts that go on from what
a failed copy leaves as `cut_short_copy` ([section 10](#what-the-port-corrects)).

**What's before the committed size isn't copied.** A `read_committed` from 0 gives the source's own bytes up to its
committed size, the padding in version 2 and the copy of the root slot in version 1, as they are, and then the
committed size for `end`. A copy at 0 writes zeros there instead. So if the source has anything but zeros there, a read
from 0 on the replica differs from what was sent in exactly those bytes. `replicate-padding` has this for version 2,
and `replicate-version-1` for version 1.

**Expectations** are assertions on the result, for reads the file can't show:

| Field | Passes when |
|---|---|
| `expect` on `read_uint`, `read_int`, `count`, `rank`, `replication_start`, `committed_size` | the integer is equal |
| `expect` on `read_float` | the bit pattern is equal ([floats](#floats)) |
| `expect` on `read_bytes`, `read_bytes_into` | the bytes are equal ([bytes](#bytes)) |
| `expect` on `slot`, `read_path_slot` | an object with at least one of `tag`, `value`, `full`: each given field is equal. It fails on a null slot |
| `expect_format_tag` | a [format tag](#format-tags) that is equal, or `null` for no tag. Left out, the tag isn't checked |
| `expect_null` | `true`: the result is null. `false`: it isn't. Left out, either is fine |
| `expect_hash` | a [hash](#hashes) that is equal. A sorted entry's hash is all zeros |

A failed expectation is a script failure, not an engine error, so `expect_error` can't catch it.

## 6. Callbacks

A `ctx` part or a `run_context` op is a Zig callback, `run(cursor: *Cursor(.read_write))`, which does this:

1. Bind `as` to `cursor.*`.
2. Run the `ops` in order.
3. If they all finished, assign `cursor.* = ` whatever `as` holds now, and return. If it doesn't hold a read-write
   cursor, that's a script failure.
4. If an error is leaving the callback ([section 7](#7-errors)), return it.

Step 3 is what makes writes through the callback's cursor visible to the path that called it. `write` on `as`
updates it, and so does a `write_path` that binds its result to `as`, which is how Zig's `cursor.* = ...` is
written. A `write_path` through `as` with no `as` of its own changes the file but leaves the cursor as it was, so
the cursor the outer call returns holds the old slot.

What comes back out of a callback is only the cursor's position and snapshot. The outer `write_path`'s result takes
its freeze point from the cursor that `write_path` was called on (`lib.zig:3203`), so a `freeze` on the callback's
cursor ends with the callback, as far as the outer result goes.

The callback runs when the path reaches it, and only then. If an earlier part fails, it doesn't run. In a read
path, `ctx` fails with `WriteNotAllowed` without running. Ops inside a callback are evaluated when they run.

Callbacks nest up to 64 deep. Each one is 5 levels of JSON, and Swift's JSON parsers stop at 512 levels. A callback's
`as` is different from the `as` of every callback written around it, and it can be the same as one that isn't. A
cursor kept in a callback can be written through from a callback nested in it, or after it has ended.

## 7. Errors

An op has a **result**: it finishes, or it raises an engine error with a name. `expect_error` says which:

| `expect_error` | The op finishes | The op raises error E |
|---|---|---|
| given | script failure | If it names E, E is handled and the next op runs. Otherwise, script failure |
| left out, inside a callback | the next op runs | E leaves the callback: its remaining ops don't run, and the op that called the callback raises E, to which this table applies again |
| left out, at the top level | the next op runs | script failure |

This is `try`: an op with no `expect_error` passes the error upward, and an op with one catches it.

A failed op doesn't bind its own `as`, `key_as` or `value_as`, and those names keep what they had. It doesn't unbind
anything either: a callback that ran before the error has already bound its own `as` and whatever its ops bound,
and those stay.

**What gets undone** is the engine's decision, not the runner's:

- When an error leaves a transaction, meaning the top-level call on the root cursor fails, the engine truncates the
  file back to the last commit. The whole transaction is gone, and the next one starts from the same bytes.
- When a callback handles an error, **nothing is undone**. The path that failed may have written to the file and
  linked what it wrote into the tree, all of which stays, and gets committed with the rest. From
  `scripts/04-rollback.json`, inside a callback, with its note left out:

  ```json
  { "op": "write_path", "on": "m", "path": [{ "hash_map_get": { "value": { "sha1": "b" } } }, { "array_list_get": 0 }], "expect_error": "KeyNotFound" }
  ```

  `hash_map_get` creates the entry for `b`, then `array_list_get` fails. After the commit `b` exists with an empty
  value. A freeze isn't undone either, and nor is what `linked_array_list_concat` does to the engine's `tx_start`, the
  position before which it treats all data as old (`lib.zig:1194`).

Truncating is all a rollback does, so it doesn't undo a write that landed before the transaction's start (section 11).

**Error names** are Zig's: `@errorName`, without `error.`. A second runner maps its own errors to these names.
`expect_error` names one of these, and no others:

| Name | From |
|---|---|
| `KeyNotFound` | a write path looking for something that isn't there. In a `read_path` or `read_path_slot` it's a null result instead, so it can't be expected there |
| `UnexpectedTag` | a path part or a read on a slot of the wrong kind |
| `WriteNotAllowed` | a writing part in a read path; `sorted_map_get_index` in a write path |
| `CursorNotWriteable` | a write to a cursor with no position; `writer` on the root |
| `ExpectedTxStart` | a write below the root, or a freeze, outside a transaction |
| `NestedTopLevelWrite` | a non-empty write path on a root cursor inside a transaction |
| `PathPartMustBeAtEnd` | a `ctx` part that isn't last |
| `ScriptAbort` | the `fail` op. It isn't an engine error, but it travels like one |
| `WriteFailed` | a transaction on a read-only file |
| `StaleCursor`, `PoisonedTransaction`, `UntrustedRootHeader`, `EmptyLastMoment`, `StructuralSlot`, `ImmutableBytes` | only with `--port`, and in the port ([section 11](#what-the-port-does)) |
| `InvalidDatabase` | `reopen`: a bad magic number, a committed size above 0 and below a new database's size, or a last trailer whose checksum doesn't match. `apply_replicated`: bytes that don't end in a trailer, or in one for another file. `read_committed` from 0: an `end` that isn't the end of a trailer. On a database without a first commit: `committed_size`, `apply_replicated` at any `start` but 0, and every read and write through the root |
| `InvalidVersion` | `reopen`: a version other than 1 and 2 |
| `InvalidHashSize` | `reopen`: a hash size in the header other than the one stated |
| `TruncatedDatabase` | `reopen`: a committed size past the end of the file |
| `EndOfStream` | `read_stream`: a `read_all` that wants more than there is. `apply_replicated`: a stream that stops before `len`, with `stream_short_by`. `reopen`: a file shorter than its database header. `committed_size`: a database without a first commit whose file is too short to hold a committed size, which is one cut off during its creation and opened read-only. It can't be named on any other op |
| `StreamTooLong` | `read_bytes`, `read_bytes_into`: a value longer than `max_size` or `size` |
| `TargetNotEmpty` | `compact`: a target with something in its root |
| `InvalidRange` | `read_committed`: a `start` after `end`, an `end` past the committed size, or a `start` above 0 that's before the committed data. `apply_replicated`: a `start` that isn't 0 or the committed size, and at 0, fewer bytes than the database header and the root header after it |
| `InvalidBTreeNode` | a read by position (`sorted_map_get_index`, `linked_array_list_get`) whose descent runs out of tree below the size its header gives. Only a tree whose header disagrees with it has such a position, which takes an undefined use to make (section 10), so a script meets one only in an input made that way |

The engine has more errors than these, like `KeyOffsetExceeded`. Reaching them takes an undefined use, a corrupt file,
or a call scripts can't make.

## 8. Transactions and commit IDs

A transaction isn't declared. It's what the engine does for a `writePath` with at least one part on a root cursor,
which is `write_path` and `write` on a root cursor, and `run_context`. What happens depends on the path:

| On a root cursor | Result |
|---|---|
| an empty path | no transaction, no commit |
| one init part matching the root's tag, like `hash_map_init` on a hash map root | no transaction, no commit: "initializing an initialized root is free" |
| anything else, succeeding | one commit, one commit ID |
| anything else, failing | rolled back, no commit ID |

The second case needs the tag to match exactly, so `{"hash_map_init": {"set": true}}` on a `hash_map` root is a
transaction, which commits and makes the root a `hash_set`. `write_if_empty` on a root cursor is a `write` if the
root is empty, and otherwise makes no call at all. A root cleared with `{"slot": null}` isn't empty, because its
`full` flag is set.

A write op on a root cursor inside a transaction, with a non-empty path, raises `NestedTopLevelWrite`. So at most one
commit happens per top-level op, and an op inside a callback never commits. Reads through a root cursor are fine
inside a transaction.

The engine asks its random source for one 64-bit value per commit, and nowhere else (`lib.zig:916`). Creating
the database doesn't, because the file ID is given and the first commit's ID is 0, and neither does `reopen`.

**There's one source of commit IDs for every database in a script.** A second runner must give the same ordered random
source to all of them, including the target that `compact` makes, which is created inside the compaction call in an
engine like Zig's, so that the source has to be passed through to it. Each commit in any of them takes the next value. The
private database behind `offset_map: "disk"` takes its commit IDs from somewhere else and is never compared. A
replica's commits arrive in the bytes applied to it, so `apply_replicated` takes none, and neither does `compact` unless
it commits.

## 9. The sidecar

`run` writes `<out.db>.sidecar.json` next to the database:

```json
{
  "format": "xitdb-sidecar/1",
  "file_id": "0011223344556677",
  "initial_size": 57,
  "file_size": 433,
  "ops": [
    {"committed_size": 433, "commit_id": "303585f7ed65083c"}
  ]
}
```

| Field | Meaning |
|---|---|
| `format` | exactly `"xitdb-sidecar/1"` |
| `file_id` | the script's file ID |
| `initial_size` | the committed size right after creating the database, which is a new database's size, 57 |
| `file_size` | the size of the file after the last op. Bytes past the last committed size are only left there by raw ops |
| `ops` | one entry per **top-level** op in the script, in the same order, including ops that are only reads |
| `ops[i].committed_size` | `db.committedSize()` after op `i`, or `null` if the database is closed by then, or in no state to say |
| `ops[i].commit_id` | 16 hex digits if op `i` committed, otherwise `null` |

An op committed if the database was open before and after it and the committed size changed. `reopen` can move the
committed size too, if the root header was changed while it was closed, but that isn't a commit. The commit ID's digits
are the 8 bytes at `committed_size − 16`, which is the trailer's commit ID field, in order. As a number, they are the
big-endian value of those bytes, which is what `randomU64` returns in Zig.

A commit's trailer doesn't have to be in the final file: if `raw_write` set the root header back, the next transaction
writes over it. Its commit ID was still used, so it stays in the list.

**A script with more than one database** has two more things in its sidecar:

```json
{
  "format": "xitdb-sidecar/1",
  "file_id": "0000000000000001",
  "initial_size": 57,
  "file_size": 91,
  "databases": {
    "main": {"file_id": "0000000000000001", "file_size": 91, "trailers": [
      {"position": 66, "commit_id": "01f1709c4e555677", "file_id": "0000000000000001"}
    ]},
    "replica": {"file_id": "0000000000000001", "file_size": 91, "trailers": [
      {"position": 66, "commit_id": "01f1709c4e555677", "file_id": "0000000000000001"}
    ]}
  },
  "ops": [
    {"committed_size": 57, "commit_id": null},
    {"committed_size": 91, "commit_id": "01f1709c4e555677"},
    {"committed_size": 91, "commit_id": null},
    {"db": "replica", "committed_size": 57, "commit_id": null},
    {"db": "replica", "committed_size": 91, "commit_id": null}
  ]
}
```

| Field | Meaning |
|---|---|
| `databases` | every database the run left a file for, including `main`, in the order it made them. A `compact` that fails before it makes its target leaves none, so that target isn't here. `file_id` is the one in that file's header by the end, and `file_size` is its size |
| `databases.*.trailers` | where the commit IDs in that file are, which `detcheck` needs and a second runner doesn't. `file_id` is what the trailer's checksum covers. One of these can be cut short by the end of a file that a sync didn't finish, and one that was overwritten by `raw_write` isn't listed |
| `ops[i].db` | the database that `committed_size` and `commit_id` are about, if it isn't `main` |

An entry is about the database the op committed in, if it did. Otherwise, it's about the target for `compact`, and for
anything else, whichever database is current after the op. So the current database after a `use` is what that entry
describes, and a write through a cursor from another database has an entry about that one. All the commit IDs in `ops`
are one list, in the order of the script, whichever database each is about.

**`apply_replicated` isn't a commit**, so its entry has a `commit_id` of `null`, and a `committed_size` that's whatever
the database says after it. For a `start` of 0, the database is replaced, so that can be **higher or lower** than
before: a replica that was ahead of what replaces it goes down, as `replicate-interrupted` does from 159 to 91. A sync
that failed at 0 leaves a database without a first commit, which can't say, and its entry has a `committed_size` of
`null`, as does each one about it until a sync succeeds. So does a database opened without a first commit, and
`reopen`'s entry after one that creates the database again has the new database's size, without being a commit.

**To reproduce a file**, give the second implementation a random source that returns the non-null commit IDs in
order, one per call. At the end, none should be left. Then after each top-level op, check the committed size
against `ops[i].committed_size`, which finds the first op that went wrong, and at the end compare the whole file.
`src/detcheck.zig` shows that the commit IDs are all it takes: it writes one run's IDs into another run's file,
recomputes the checksums, and gets the first file back exactly.

The checksum is computed by the engine and isn't in the sidecar. It should come out equal by itself.

## 10. Valid scripts and script failures

```
run <script> <out.db> [--kind buffered_file|file|memory] [--allow-port-differences] [--port] [--inputs <dir>]
```

The Zig runner truncates `<out.db>`, runs the script, and writes the file and the sidecar. The default kind is
`buffered_file`. It uses `fsync = false` and the default buffer size, neither of which affects the bytes. It exits with:

| Status | Meaning |
|---|---|
| 0 | the script is valid, it ran to the end, and every expectation passed |
| 1 | the script isn't valid or it failed, or a file couldn't be opened. The output files must not be used |
| 2 | wrong command line |

A panic in the engine means an undefined use or an engine bug, and nothing that's among the fixtures causes one.

A second runner reads a script and a sidecar. How it's started is up to it, and it needn't write a sidecar. The three
kinds of problem below matter to it differently.

### A script that isn't well-formed

Being well-formed is everything sections 1 to 6 say about how a script is written. `run` checks all of it, for the
whole script, before it creates the database. That includes ops that are never reached, fields that would only be
looked at if a call finished, and the bodies of callbacks that never run. `run` also fails on a duplicate field,
`1.0`, `1e0`, `-0`, a trailing comma and a byte order mark. `tests/invalid/` has scripts it has to reject, and these
include the undefined uses it can catch.

So a script `run` has accepted is well-formed everywhere. A second runner can decode all of it up front or take it
piece by piece, and need not reject any of the above. Swift's JSON parsers accept several of them, and it doesn't
matter, because they don't appear. It only has to fail on what it doesn't know (section 1).

### A script failure

A failure that can only be known by running the script:

- an engine error that nothing handled ([section 7](#7-errors)),
- `expect_error` on an op that finished or raised a different error,
- a failed expectation,
- a name that isn't bound, or that holds the wrong kind of thing ([section 4](#4-names)),
- a callback's `as` not holding a read-write cursor when it ends,
- a null slot given to `linked_array_list_concat`.

The runner stops there. **A second runner must do this too.** Each script in `tests/failing/` is well-formed and must
fail in every runner. The text after `expected failure:` in each one's `description` is the reason in Zig's message;
message wording isn't part of this format.

These scripts have no sidecar, because a failed run leaves no file to compare. Some commit before they fail, so the
random source has to return something, and any values will do.

### An undefined use

Things a well-formed script could say, whose results aren't defined. Scripts don't contain them, and a second runner
needn't handle them. They are kept out like this:

| Use | What Zig does | How it's kept out |
|---|---|---|
| Using a cursor or a slot from a transaction that was rolled back | reads whatever is at that offset by then, which can be anything | `run` fails. With `--port`, a read or a write through one raises an error instead (section 11), and the rest is still kept out |
| Writing a slot whose tag is `index`, `kv_pair` or `sorted_kv_pair` | follows it as if it had been built there, which ends in errors like `KeyOffsetExceeded` | `run` fails. With `--port`, every way to write one raises `StructuralSlot` instead (section 11) |
| Reading, before the commit, a gap left by a `writer` that seeked past the end | zeros on `file` and `memory`. On `buffered_file`, `EndOfStream` until the gap has been flushed, and zeros after that. The committed bytes are the same on all three | `EndOfStream` can only be expected on `read_stream`, and `check.sh` runs every script on all three kinds. A read that gets zeros everywhere isn't caught |
| On a read-only file, a transaction with a callback, or one that would fail anyway | `file` raises `WriteFailed` at the first write, without running the rest. `buffered_file` runs the rest and only fails at the commit, so it raises `KeyNotFound` for a path that fails by itself, runs the callback, and raises `ScriptAbort` for a callback that fails | `run` fails on the callback. `check.sh` runs every script on both kinds, which catches the rest |
| A write into committed bytes (section 11) of something that points into the current transaction, if the transaction is then rolled back or the root header is later set back past it | committed data is left pointing past the end of the file. Reading it raises `EndOfStream`, or `OutOfMemory` for a wild length, and once more data has landed at that offset, the read succeeds and returns those bytes as if they were the value | `gen` doesn't let such a transaction fail. `run` can't see it, so a hand-written script has to take care: writing an inline value is fine, as `overwriting-committed-bytes` does |
| **Two headers for one tree.** An init copies a linked list's or sorted map's header if it's old, and the copy shares the tree. That's only safe if the nodes are old too, or nothing can see the old header any more. There are three ways it goes wrong, all in one transaction. After `linked_array_list_concat`, the old header points at a node that's newer than the transaction's start, so it's rewritten in place, and the old header can still be reached through a slot read before or copied after, a cursor kept from before, or a stale snapshot. After a freeze on a cursor to a collection that a cursor that isn't frozen can also reach. And after a skipped init on a tree, followed by an init | the header disagrees with its tree. A read past the end raises `InvalidBTreeNode`, and some raise `InvalidEnumTag`. An append panics, or crashes in a release build | `gen` keeps away from all three. `run` can't see them, so a hand-written script has to take care. `tests/undefined/` shows them, and makes the inputs `sorted-*` and `linked-*`: committed files, with no byte damaged, that the second way left in each of its four shapes, on a sorted map, a sorted set and a linked list. A valid script can read one of those, and only read it, as the scripts of the same names in `tests/valid/` do. Two of those reads are ones the port corrects ([below](#what-the-port-corrects)), and an iterator from a position past the tree can panic (`frozen-clone-*-iterator-past-tree`) |
| Using an iterator after a write in the transaction that made it. It holds copies of the blocks it's part way through, and reads the others when it gets to them | what's been rewritten in place shows up if the iterator hadn't read that block yet, and doesn't if it had | `run` fails. A hand-written script also has to take care with one kept past a write into committed bytes (section 11), which `run` can't see |
| A trie 64 levels deep, at a hash size above 32. Two keys need to share their lowest 64 nibbles, which for real hashes would take a 256-bit collision | a depth counter overflows, which panics in a debug build | `run` is a debug build |

`tests/undefined/wrappers.zig` shows that the collection wrappers alone can reach two headers for one tree, without the
path API. What it does depends on the collection, since only the trees index a node by a count held elsewhere:

| Collection | What a stale header leads to |
|---|---|
| `linked_array_list` | a read raises `InvalidBTreeNode`. An insert, an append or a remove panics, and crashes in a release build |
| `sorted_map`, `sorted_set` | a read by index raises `InvalidBTreeNode`. A remove can underflow the count, which panics, and wraps in a release build |
| `counted_hash_map`, `counted_hash_set` | a remove can underflow the count in the same way. Nothing else depends on the count |
| `array_list`, `hash_map`, `hash_set` | no crash, only what's written to one showing up in the other |

### What the port corrects

The user has decided that the port differs from Zig in these reads from the start, so a valid script can't use them
(findings 8, 9, 21 and 26 in `director/zig-findings.md`). A second runner doesn't need to do anything about them, and `run`
fails on a script that uses them, unless it's given `--allow-port-differences`. `tests/port-differs/` has a pair of
scripts for each, one with what Zig does and one with what the port does.

| Use | Zig | The port |
|---|---|---|
| `read_bytes_into` with a `size` above 0, on a slot with nothing in it | `EndOfStream` | it's empty |
| `read_stream` on a slot with nothing in it | `UnexpectedTag` | an empty stream |
| `read_stream` on a `short_bytes` slot from a cursor with no position, which is a key from `{"sorted_map_get": {"key": ...}}`. Since `71ee0cf`, the key `read_key_value_pair` gives for a set's entry has the entry's position, and streams in both | `ExpectedSlotPosition` | it gives the value |
| `read_stream` on a `short_bytes` slot that has since been overwritten | the length from the cursor and the bytes from the file, so neither value | it gives what the cursor holds |
| `next` on an array list's iterator, when what it would give is past the end of the list. It stops after giving as many elements as the list has, it skips a slot that's truly empty, and a slice leaves what's past the new end in its blocks. Since `89da8e7` an append writes a `none` slot marked full, which isn't skipped, so only a version 1 file written before it can have this: `[unwritten, 1, 2, 3]` sliced to a size of 2 at `6b93af1` gives 1 and 2 | it gives what `{"array_list_get": 2}` says isn't there | it goes through the positions up to the list's size and no further, so here it gives 1 |
| `iterator` with `from_index` on a sorted map or set, or a linked array list, at a position below its size where a read by position raises `InvalidBTreeNode` (`iterator-from-position-past-tree`) | it starts there without checking the index it lands on in the leaf (`lib.zig:3731`, and `3800` for a list), and gives nothing, or what comes after the leaf, or panics at the first `next` when the leaf is fuller (`tests/undefined/frozen-clone-*-iterator-past-tree`) | `iterator` raises `InvalidBTreeNode`, from its starting descent |
| `iterator` with `from_key` on a sorted map or set, from a key whose place, its `rank`, is past the collection's `count` (`iterator-from-key-past-size`) | it stops only when its index equals the size, so it goes on to the tree's end | it gives nothing |

The last two need a tree whose header disagrees with it, which only an undefined use makes (section 10: two headers for one
tree), so a script meets them only on one of the inputs made that way. **Neither can happen on a tree whose header agrees
with it.** There, every position below the size is in the tree, so a read by position can't run out of tree, and a key's
place is the number of keys before it in the tree, which can't be more than the tree holds, and so not more than its size. `run`
checks both at the `iterator` op, with a read at the position and a `rank` of the key, so a valid script that starts an
iterator anywhere else isn't touched.

**A full copy into a file** (D55). Here the port differs by storage kind, not by script, so unlike the reads above,
valid scripts go on using it. In the original, and in the port's memory storage and a storage of the caller's own, a sync
at 0 copies in place. One that fails after it has read the database header and the root header after it, because its
stream stops (`EndOfStream`) or its bytes don't end with a trailer (`InvalidDatabase`), leaves a database without a first
commit: the source's database header, a root header of zeros, and every block of 4096 bytes that arrived whole. Its
`committed_size`, and every read and write through the root, raise `InvalidDatabase`, and its replica state is zero and
zero. A `reopen` creates it again if it's no bigger than a new database, and opens it as it is otherwise, and the port's
`recover` cuts it back to the last trailer that arrived whole. In the port's file storages, the copy goes into a new file
beside the old one, which takes the old one's name only once the copy's committed size has been written and synced. One
that fails raises the same error, and leaves the database as it was before the sync, in every byte, and so does a process
that dies during it: its committed size, its replica state and its reads are what they were. A copy that succeeds leaves
the same bytes either way, and one given too few bytes for the two headers raises `InvalidRange` and changes nothing in
both. A copy that replaces can also fail where the original's can't, when the new file can't be made or given the name,
in a folder the process can't write to or with no room for a second file. That's the port's alone: it raises the
system's error, and leaves the database as it was.

The fixtures that go on from what a failed copy leaves are what the original does, and the manifest gives them the
feature `cut_short_copy`. It finds them from each script and its sidecar: a top-level `apply_replicated` that raised the
error it expected, and whose sidecar entry has a `committed_size` of `null`, as a failed apply changes nothing unless it's
a copy at 0 that has begun to write, and that's what leaves a database without a first commit. A port's runner leaves
them out on a storage that replaces, where the port's own tests hold what a failed copy leaves, with every file call
failing in turn and a process that dies at four points. `run --port` does nothing about it, as each of `run`'s storage
kinds copies in place, as the port's memory storage does, so the fixtures are what the port does there. There's no
pair in `tests/port-differs/`, as its second script would need a runner whose storage replaces, which the original
doesn't have. A file without a first commit that raw ops made isn't marked, as what's tested there is opening it, which
every storage has to do, whoever wrote the file.

**Storage kinds don't otherwise change the bytes.** `check.sh` holds every script in this repository to that, across
all three kinds, in debug and release builds.

## 11. Behaviour a runner must not fix

All of these look like mistakes and all of them are what Zig does. `overwriting-committed-bytes`, `path-api-edges` and
`every-construct` in `tests/valid/` pin them down, with `-linked` and `-sorted` versions for those collections.

1. **The path API doesn't protect committed bytes.** A collection's init part is what copies it into the
   transaction, and nothing makes a path run one. A path that skips it writes straight into the committed collection,
   so earlier moments change: a list grows, an element changes, a map gets a key. A write through a cursor kept from
   an earlier transaction does the same, however many new cursors were made from it in between. Neither is an error,
   and a rollback doesn't undo them, because truncating only removes bytes past the commit, which is an undefined use
   if what was written points at bytes that were removed (section 10). The collection wrappers don't do this, because
   they always run the init part. Storage kinds agree on the result. The port refuses both: the first with `ImmutableBytes`
   and the second with `StaleCursor` ([below](#what-the-port-does)), so `overwriting-committed-bytes` and its `-linked` and
   `-sorted` versions are only for Zig, and each has a `--port` version.
2. **A remove ends the path.** `hash_map_remove` and `sorted_map_remove` return without looking at the parts after
   them, with no error. A `write` after one does nothing, and a `ctx` after one doesn't run.
3. **`write_path` doesn't update the cursor it's called on** (section 4), so a callback that only uses `write_path`
   on its own cursor returns its old slot.
4. **A failed path keeps what it wrote** if the error is handled in a callback (section 7). For example,
   `{"sorted_map_get": {"key": "b"}}` followed by `{"write": ...}` fails with `CursorNotWriteable` after inserting
   `b`.
5. **`sorted_map_get_index` only works in a read path.** It's the one getter that fails with `WriteNotAllowed` in
   a write path.
6. **A sorted map's key can be written one way but not the other.** Through `{"sorted_map_get": {"key": ...}}` the
   cursor has no position, so writing fails with `CursorNotWriteable`. Through `read_key_value_pair` on a
   `{"sorted_map_get": {"kv_pair": ...}}` cursor, it has one, so writing works, and writing a different key would
   break the order.
7. **Asking a set for a pair changes the entry.** `{"sorted_map_get": {"kv_pair": ...}}` in a write path moves a
   key-only entry into a `sorted_kv_pair`, even in a `sorted_set`.
8. **Writing `none` sets `full`, and keeps the value.** `{"write": {"slot": {"tag": "none", "value": 5}}}` writes
   tag `none`, `full` set, value 5.
9. **Nothing stops a stale snapshot being used** (section 4). `read_uint` on a cursor whose slot has since been
   written reports `UnexpectedTag` if the old slot wasn't a `uint`, and `write_if_empty` overwrites a value it can't
   see.
10. **A freeze doesn't leave a callback** (section 6). The cursor the outer `write_path` returns has the freeze point
   of the cursor it was called on, whatever its callback did to the cursor it was given.
11. **Opening a file doesn't clean it up.** Bytes past the committed size stay until a write, and a free init on a
   read-only file doesn't report that it couldn't truncate them. Only the committed size in the root header is ever
   read: what's before it can be garbage, the padding in version 2 or the copy of the root slot in version 1, and the
   root comes from the trailer anyway. A commit writes only the committed size, so garbage there stays
   (`recovery-garbage-padding`, `recovery-torn-root-slot`).
12. **An element appended and never written is a `none` slot marked full**, in both lists, since `89da8e7` for an array
   list. It's the same as one set to nothing: it counts, a lookup gives that slot, an iterator gives it, and a typed read
   of it raises `UnexpectedTag` (`unwritten-elements`). In a version 1 file written before it, an array list's is a slot
   that's truly empty, which a lookup gives as null and an iterator skips (`tests/port-differs/iterator-past-slice`).
13. **Compacting a history with no last moment loses the history.** A list at the root with no moments compacts to an
   empty root, and not to a list, and so does one whose last slot is truly empty, which only a version 1 file written
   before `89da8e7` can have: every moment written before that last one is lost with it. One whose last element was
   appended and never written since then is a moment set to nothing, and compacts. The port refuses the first two
   ([below](#what-the-port-does)), so `compact-roots` is only for Zig, and `compact-roots--port` is its version.
14. **A failed sync at 0 leaves a database without a first commit.** Since `92a926e` the copy writes the source's
   database header and a root header of zeros first, and the committed size last, so what's there can't say its committed
   size, can't be read or written, and gives zero and zero as its replica state, until a sync at 0 succeeds. It still
   opens, as a full copy that didn't finish, and a file without a first commit that's no bigger than a new database is
   created again when it's opened (section 5). Zig's README says a caller who minds should write the copy to a new file.
   The port's file storages do that themselves, so there a failed sync at 0 leaves the database as it was, and the
   scripts that go on from what it leaves here are marked `cut_short_copy` ([section 10](#what-the-port-corrects)).

### What a later Zig changes

Apart from what this says, all of this document is what Zig does at `89da8e7`. The manifest gives each fixture's
`zig_commit`, and its expected file is what that commit does. These fixtures are from the fixes branch, `fix-findings-v2`
at `bd6abc3`, on `89da8e7`, as they need its bytes:

| Fixture | What it needs from there |
|---|---|
| `write-if-empty-emptied-slot`, `path-api-edges--port` | Finding 17: `write_if_empty` goes by the slot as it is now, not the snapshot. If the cursor has a position, it reads the slot there when it's called, and it writes if that slot is empty, or if the cursor's own slot is empty and the slot now is a `none`, as an append leaves it. Empty means the tag is `none` and `full` isn't set, so a slot written with `{"slot": null}` isn't empty. A root cursor is as it was. So section 4 and item 9 above don't hold for them |
| `every-construct-linked--port` | Finding 22: a concat freezes after its join, so what comes after it in that transaction copies the joined nodes |

A runner's calls don't change for any of this, only what the engine under them does.

### What the port does

**The fixtures are what the port has to do**, once it has its guards (D16 to D19, D22 and D24 in `director/decisions.md`). So
they are what Zig does, apart from this. `run --port` acts it out on the Zig engine, and that's what writes the expected files. It
can, because **each guard refuses before writing anything**, so the file stays as if the op had never been there. The one that
refuses at the write, row 9, has its own paragraph below.
`tests/zig-only.txt` lists the scripts that do what the port refuses, which aren't fixtures. `tests/port-variants/` has the
port's versions of those written by hand, as `<name>--port`, and a few that are an undefined use in Zig, whose oracle is Zig on
the same script without what the port refuses.

These are checked in this order, for an op that goes through a cursor. **They cover every way to write and every way to
read**, and a runner has to put them in front of each:

- The writes are `write_path`, `write`, `write_if_empty` and `writer`, the byte writer, which is checked once, before its
  first step.
- The reads are every op that goes to the file through a cursor or an iterator: `read_path`, `read_path_slot`,
  `read_key_value_pair`, `read_uint`, `read_int`, `read_float`, `read_bytes`, `read_bytes_into`, `read_stream`, `count`, `rank`,
  `iterator` and `next`. `slot` isn't one, as it gives what the cursor holds, and nor is `read_only`, which reads nothing.

In the port, there are more ways to get to each: a collection's own methods, a byte writer kept between calls, an iterator, a
read-only view. Each of them carries the transaction and the freeze of the cursor it's from, and is refused in the same way.
The port's own tests found that its first guards missed the byte writer for row 4, and iterators and read-only views for row 1.

| | What | It raises |
|---|---|---|
| 1 | A read through a cursor from a transaction that was rolled back, whose bytes are gone and whose offsets get reused | `StaleCursor` |
| 2 | A write through such a cursor | `ExpectedTxStart` with no transaction going, and otherwise `StaleCursor` |
| 3 | A write in a transaction that's poisoned | `PoisonedTransaction` |
| 4 | A write through a sorted entry's key cursor, from `read_key_value_pair` (finding 2) | `CursorNotWriteable` |
| 5 | A write during a transaction through a cursor from an earlier one (finding 1). **That includes an init**, which would rewrite a slot that's committed | `StaleCursor` |
| 6 | A write through a cursor made before the last freeze in this transaction (D24), **an init included**. The exception is **through a cursor at the transaction's body's slot** (below): a `write_path` whose path begins with an init part (D24 item 1) or a `write` part (item 3), and so `write`, which is a one-part write path, and `write_if_empty`, which calls it. That's the way to go on after a freeze, and what follows the first part goes through what it made or wrote. A `writer` through it, an empty path and a path that begins with any other part are still refused. An init or a write through a cursor at any other slot would write that cursor's slot in place, in a record from before the freeze, which a clone or a second way down from the root may have copied, and the write would be lost (findings 29 and 30, `held-init-after-root-copy`) | `StaleCursor` |
| 7 | A path with anything after `hash_map_remove` or `sorted_map_remove` (finding 12), on any cursor. It raises before removing anything | `PathPartMustBeAtEnd` |
| 8 | A slot whose tag is `index`, `kv_pair` or `sorted_kv_pair` (finding 3), which is part of a collection's structure: in `write`, in `write_if_empty` whatever the slot holds, or in a path's `write`, before any of the path's parts run. So nothing is written, and through the root no transaction begins. With no transaction going, `write` and `write_path` below the root raise the engine's `ExpectedTxStart` first, as they always do, and `write_if_empty` raises this, as it doesn't try to write | `StructuralSlot` |
| 9 | A write that would change a byte below the transaction's frozen point, which is where it began or where its last freeze was, apart from the body's own slot: committed or frozen bytes (D24). It's checked at the write, so whatever passed rows 1 to 8, as finding 13's path that skips an init on a fresh cursor does, and what was written before it can poison the transaction (below) | `ImmutableBytes` |

What the words mean:

- **A cursor is made** when the op that binds it begins, or for a callback's own cursor, when the callback starts (D24 item 6a).
  So what an op gives back counts as made before any freeze during it: a concat's result, and the cursor a path gives back after
  a `db_freeze` in its callback. One made through a stale cursor is fresh from then on. `write` and the others that update a
  cursor don't make it fresh. An iterator is made when `iterator` begins, so `next` on one made in a rolled-back transaction
  raises `StaleCursor`.
- **The transaction's body** is the cursor a top-level op's callback is given, by the `ctx` part at the end of its path or by
  `run_context`. Its slot is in the transaction's own record, the root or the moment it appends, which nothing that starts inside
  the transaction can copy, as a write through the root there raises `NestedTopLevelWrite`, and each write reads the slot again.
  So **the exception goes by the slot, not the cursor**: an init or a write can go on after a freeze through any cursor whose
  slot is the body's, made before the freeze or after it, like what `[]` or `[{"hash_map_init": {}}]` through the body gives
  back. `body-write-after-freeze--port` has each of them, and what stays refused.
- **A read-only view isn't made.** `read_only` gives the cursor it's on, read-only, so the view keeps that cursor's transaction
  and freeze. A read through a view of a cursor from a rolled-back transaction raises `StaleCursor`, as one through the cursor
  does, and `read_only` itself raises nothing.
- **A freeze** is `db_freeze` or a concat. It isn't `freeze` on a cursor, which is finding 23, and nothing changes for that. What
  a concat gives back counts as made before its freeze, so it's stale, as is the cursor it was called on.
- **A root cursor is never stale**, as it reads the last commit. An empty path is a write here, as it would give a stale cursor
  a fresh one.
- **With no transaction going, nothing is stale**, so rows 5 and 6 don't apply: a write raises `ExpectedTxStart` from the engine,
  as it always has, and a `write_path` with an empty path works. Row 9 holds at the top level too, below the committed size.
- **Reads through a stale cursor stay valid**, apart from row 1. They're snapshot reads, and with stale writes refused,
  nothing changes those bytes under them.

Anything else through a cursor or an iterator from a rolled-back transaction, like `slot` or `freeze`, is still an undefined
use, as in section 10.

**A transaction is poisoned** by an op in a callback that raises an error that's handled with `expect_error`, having written
something (finding 16). An op has written something if it issued a write to storage, **other than an init writing back its slot
unchanged**. An init always writes its slot back, even when it copied nothing, so `[{"hash_map_init": {}}, {"hash_map_remove": ...}]`
on a key that isn't there has written nothing. That takes no read, as the init has the slot in hand. An op refused by the table
above writes nothing, so it poisons nothing. From then on every write raises `PoisonedTransaction`, and so does the transaction's
end: it's rolled back when the outermost callback returns, the top-level op raises it, and it takes no commit ID. Reads go on
working until then. This is what Zig does with that transaction made to fail.

`run --port` goes by whether a byte of the file changed, as Zig has nowhere to count writes. The two agree on every fixture,
which was measured with a counter in a copy of the engine. **They can differ in one shape, where a port may poison or not**: a
`write_path` where a part fails after a `sorted_map_get` on a key that's already there, in a tree made in this transaction. That
get writes the tree's header back unchanged. It takes the path API, as a wrapper's `put` ends with a write that can't fail
like that. No fixture does it, and `gen --port-safe` can now and then, with `sorted_map_get_index` as the part that fails, so a
fresh script can differ there without either side being wrong.

**The position check**, row 9, fires at the write it refuses, not before the op (D24 items 2 and 6c). A write that leaves the
bytes as they were isn't refused, and nor is one at the body's slot. A part that writes a header in place checks where the
header is first, and writes nothing if it's refused: the linked list's append, insert, remove, slice and concat, the sorted map's
get in a write path and its remove, the array list's append and slice, and the counted map's get and remove. Any other part, or op,
can have written before the write that's refused, as Zig's order has it: a hash map's get that adds a key writes the new entry and
then its slot, an init its copy and then the slot, a `write` of a value that doesn't fit in a slot the value, and a `writer` its
bytes, before the slot. What was written before the refused write stays, and **a copy is a write**. If it changed a byte, the op
has written something, and it poisons the transaction as any failed op that wrote does: the oracle is Zig with the transaction made
to fail. If it didn't, the oracle is Zig on the script without the op. So a path that skips an init through the moment's map, whose
get copies the entry's record before it gets there, poisons, and an append through a fresh cursor at the committed list doesn't. Only the path API gets this far, as every collection wrapper runs the init part: no other way reaches
`ImmutableBytes`.

`run --port` acts it out by running the op on Zig and comparing the bytes below the frozen point before and after, leaving out the
root header, which a commit writes, and the body's slot. If one changed, it puts the file back, and finds the refused part by
running the path again a part longer each time, putting the file back after each. Then it runs the parts before that one again,
and the refused part too if it isn't one that checks first, putting back the bytes below the frozen point after it. For `write`,
`write_if_empty` and `writer`, the op is the refused part. Then it raises `ImmutableBytes`, and the transaction is poisoned if a
byte changed, as for any failed op. An op with a callback is held to it when the callback starts, as what's
written after that is the ops in it, each held to it by itself. At the top level, a refused op's transaction fails, which leaves
the file as it was, but only if Zig's op failed too or had a callback: one that succeeded has been committed by then, so `run
--port` can't undo it, and that's a script failure.

**Opening.** A `reopen` raises `UntrustedRootHeader` if the committed size in the root header is past the end of the file,
above 0 and smaller than a new database, or doesn't end at a trailer whose checksum verifies. Those are where Zig raises
`TruncatedDatabase` or `InvalidDatabase`. A bad magic number is still `InvalidDatabase`, and a bad version or hash size is what
it was. It leaves the database closed, as any failed `reopen` does. **A committed size of 0 is a database without a first
commit**, which the original now defines, and the port does there what the original does (D31 item 4): it creates a file
that's no bigger than a new database again, opens a bigger one as it is, and raises the original's errors on it
(section 5). So does a file too short for its database header, which raises `EndOfStream`.

| `op` | Other fields | What it does |
|---|---|---|
| `recover` | | The port's recovery call, at the top level, while the database is closed |

It looks from the end of the file back, a byte at a time, for the last position that ends a trailer whose checksum verifies,
using the file ID in the file's header. It cuts the file off there, and writes that position as the root header's committed
size, at offset 24 in version 2 and 29 in version 1, and leaves what's before it as it is, so a version 1 file's copy of the root
slot isn't updated, as the original no longer updates it (D31 item 1). Then it opens the database, which is left open. It takes no commit ID, and a top-level op with it
in has no commit. A commit past that position is lost, and its commit ID stays in the sidecar, as it was used. With a bad magic
number, or no trailer that verifies, it raises `InvalidDatabase`, and the database stays closed. So all it leaves is what the
file held just after that commit, and nothing is dropped except by this call.

**Compacting a history with no last moment.** A `compact` raises `EmptyLastMoment` if the current database's root is an
array list with no elements, or whose last element is empty: its tag is `none` and `full` isn't set (finding 28). Since
`89da8e7` that's only so in a version 1 file, where an element appended and never written is that, as an append now writes a
`none` slot marked full, which is a moment set to nothing, and compacts as one, as before. This is checked before anything else the compaction
does, the target included:

- a target with something in its root raises `EmptyLastMoment` too, and not `TargetNotEmpty`;
- a name that wasn't a database yet still isn't one, so a later `compact` into it needs a `file_id`, as any new one does;
- a target that was empty is left as it was, as is the source.

So it's what Zig writes with that `compact` left out.

## 12. Worked example

`tests/valid/worked-example.json`, whose ops are:

```json
{ "op": "write_path", "on": "root", "path": [
  "array_list_init",
  "array_list_append",
  { "hash_map_init": {} },
  { "hash_map_get": { "value": { "sha1": "foo" } } },
  { "write": { "uint": 42 } }
] }
```

With file ID `0011223344556677`, hash ID `sha1`, hash size 20 and the commit ID `303585f7ed65083c` it makes 433
bytes, 376 of them after the new database's 57. A commit ID is random, so the fixture of this script, which came from
another run, has a different one, and a different checksum after it. Its other bytes are these:

| Offset | Bytes | What |
|---|---|---|
| 0 | `78 69 74` `00` `00 02` `00 14` `73 68 61 31` `00 11 22 33 44 55 66 77` | database header: magic number, a zero byte, version 2, hash size 20, hash ID, file ID |
| 20 | `00 00 00 00` | padding |
| 24 | `00 00 00 00 00 00 01 b1` | root header: committed size 433 |
| 32 | 9 zero bytes, 8 zero bytes, `be 37 af 4a 96 7c c5 50` | trailer of the new database: empty root, commit ID 0, checksum |
| 57 | `02 00 00 00 00 00 00 00 42` | the transaction's scratch slot, holding the new root |
| 66 | `00 00 00 00 00 00 00 01` `00 00 00 00 00 00 00 52` | array list header: 1 element, index block at 82 |
| 82 | `04 00 00 00 00 00 00 00 e2`, then 135 zero bytes | index block. Slot 0 is the element: a `hash_map` at 226 |
| 226 | 27 zero bytes, `05 00 00 00 00 00 00 01 72`, 108 zero bytes | the map's index block. Slot 3 (the hash ends in `33`) is a `kv_pair` at 370 |
| 370 | `0b ee c7 b5 ea 3f 0f db c9 5d 0d d4 7f 3c 5b c2 75 da 8a 33` | the pair's hash |
| 390 | 9 zero bytes | the pair's key slot, empty |
| 399 | `08 00 00 00 00 00 00 00 2a` | the pair's value slot: `uint` 42 |
| 408 | `02 00 00 00 00 00 00 00 42` `30 35 85 f7 ed 65 08 3c` `1a 17 6f d7 f2 19 b5 fc` | trailer: root slot, commit ID, checksum |

The checksums are CRC-64/XZ of file ID, trailer position, root slot and commit ID, as in `file-format.md`. Both of
these were recomputed with a separate implementation of the CRC. In version 1 the committed data starts five bytes later,
at 37, and so does every offset in it, and the root header at 20 is the root slot and then the committed size:
`02 00 00 00 00 00 00 00 47` `00 00 00 00 00 00 01 b6`, for 438 bytes in all.

The sidecar for this run is the one in section 9.

## 13. Not in this version

These are Zig API that scripts can't call yet.

- A byte writer left open across other ops, which is the only other way to reach `WriteFailed`, and the only way to
  reach `UnexpectedWriterPosition`.
- A compaction into a storage kind other than the source's.
- A disk-backed offset map other than the one in `offset_map: "disk"`.

## 14. Changes to this version

Scripts stay `xitdb-script/1` when the format only grows, because nothing an existing script says changes meaning, and
a runner that doesn't know an op has to fail when it reaches it (section 1). The manifest says which scripts need what.

**Closing and reopening were added.** A runner written before them runs every earlier script unchanged. To run the new
ones, it needs:

- the ops `close`, `reopen`, `raw_append` and `raw_write`, and a way to write to storage directly (section 5);
- to state a hash size when reopening, rather than taking it from the file;
- the five error names they added (section 7);
- `null` as a `committed_size` in a sidecar, and to expect a `committed_size` to go down after `reopen` (section 9);
- to compare the whole file at the end, as before, including any bytes past the last committed size.

**Reads were added**, and they change no bytes. A runner written before them runs every earlier script unchanged. To
run the new ones, it needs:

- the ops `iterator`, `next`, `rank`, `read_bytes_into` and `read_stream`, and `max_size` on `read_bytes` (section 5);
- iterators as a new kind of thing a name holds, which `next` changes (sections 4 and 5);
- the error names `EndOfStream` and `StreamTooLong` (section 7).

The manifest lists what each script uses as `iterators`, `rank`, `byte_stream` and `byte_buffers`. The last is
`read_bytes_into` and `max_size`.

**Several databases, compaction and replication were added.** A runner written before them runs every earlier script
unchanged, and a script with only one database has the same sidecar as before. To run the new ones, it needs:

- the ops `create_database` and `use`, and a current database for `root` and everything with no `on` to act on, while a
  cursor stays with the database it came from (section 5);
- **one source of commit IDs across all the databases in a script**, including a target made by `compact` (section 8);
- the op `compact`, for M7, and the ops `replica_state`, `replication_start`, `committed_size`, `read_committed` and
  `apply_replicated`, for M8, with numbers, a replica's state and committed bytes as things a name can hold (section 5);
- the error names `TargetNotEmpty` and `InvalidRange`, and `EndOfStream` on a few more ops (section 7);
- to read `db` in a sidecar's entries, and to expect a `committed_size` that goes down or is `null` after `apply_replicated`
  (section 9);
- to compare `<name>.<database>.db` as well, for each of `other_databases` in the manifest.

**The original moved to `89da8e7`, with format version 2** (conformance-09, 2026-11-13). Every script that creates a
database now gets a version 2 file, five bytes shorter before its data, and the expected files and sidecars moved with
it. Nothing else a script says changes meaning. To run the scripts at the new pin, a runner needs:

- format version 2, and version 1 files opened as version 1 (section 1);
- the ops `raw_load` and `raw_truncate`, `file_id` and `hash_id` on `reopen`, and the fixtures' `inputs/` folder, which
  the manifest lists for each script as `inputs`, with the feature `inputs` (section 5);
- `EndOfStream` on `reopen` (section 7);
- what `52c7283` to `89da8e7` changed: a database without a first commit, which a failed sync at 0 leaves and a file cut off
  during its creation is created again from (sections 5 and 11), an element appended and never written that counts, and
  a set's key from `read_key_value_pair` that streams.

**The manifest's `other_databases` goes by the sidecar** (2026-11-14, after conformance-09). It used to name every
`create_database` and every `compact`'s target in a script's text, so it named a target `compact-sliced-history--port`'s
guard refuses before making it, and there's no file for that. Now it names the databases in the sidecar's `databases`,
apart from `main`, which are the ones the run left, and the gate checks that every path the manifest names is in the
fixtures, and that every file there is named by it or is one the fixtures' README lists. Nothing a script says changes
meaning, and no expected file moved.

**Clones the freeze hazard leaves, as inputs** (2026-11-15, after conformance-09). Eight inputs, `sorted-*` and `linked-*`,
are clones with a header that disagrees with its tree, which only an undefined use makes (section 10), each made once on
the original at `89da8e7` by its maker in `tests/undefined/`. The scripts in `tests/valid/` with the same names read them,
and pin what the original gives. To run those, a runner needs:

- the error name `InvalidBTreeNode`, which a read by position raises where its descent runs out of tree (section 7);
- nothing for the two reads the port corrects on them (section 10), which `run` keeps out of valid scripts.

`run` takes `--allow-port-differences` for the scripts in `tests/undefined/` too, as two of them panic in reads the port
corrects, and a case there that prints nothing has no text to look for in `expected.txt`.

**The feature `cut_short_copy`** (2026-11-17, D55). The port's file storages replace the file on a full copy, so a sync
at 0 that fails leaves the database as it was there, and not a database without a first commit (section 10). The
manifest gives `cut_short_copy` to the scripts that go on from what a failed copy leaves, finding them from each script
and its sidecar, which `check.sh` holds to `replicate-copy-cut-short`, `replicate-failed-first-sync` and
`recover-without-first-commit--port`. A runner leaves them out on a storage that replaces, and runs them as before on one
that copies in place. The first half of `recover-without-first-commit--port`, `recover` on a file cut off during its
creation, which no sync made, is `recover-cut-during-creation--port` now, so it runs on every storage. Nothing a script
says changes meaning, and no other expected file moved.
