# Script format, version 1

A script is a JSON document describing a sequence of calls on an xitdb database, at the level of Zig's path
API. `src/run.zig` executes a script on the Zig implementation and records the resulting file. A second runner
executes the same script on another implementation, feeding it the commit IDs Zig chose, and must then produce
the same file, byte for byte.

**Each op is one call.** A runner looks up the names an op refers to, builds the arguments, makes the call and
binds the result. It adds no checks and no recovery of its own: if the engine does something odd, the script
is there to pin it down. Section 11 lists the oddities a runner might be tempted to fix.

The examples below are taken from scripts that run: `scripts/` holds the hand-written scripts, and
`tests/valid/` covers every construct in this document.

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
| `description` | no | ignored |
| `hash_size` | yes | size of a hash in bytes, written to header bytes 6–7. Scripts use 8, 20, 32 or 64, the sizes the Zig runner is compiled for |
| `hash_id` | yes | [bytes](#bytes), exactly 4, written to header bytes 8–11; or `null`, for 4 zero bytes |
| `file_id` | yes | exactly 16 hex digits, the 8 bytes of header bytes 12–19 in order |
| `ops` | yes | the [ops](#5-ops), run in order |

The runner starts with an empty file, creates a new database with these parameters, and runs the ops. Creating
the database commits an empty root with commit ID 0, which gives the 62-byte file described in `file-format.md`.

**A runner must fail on anything it does not recognise**: a field, an op, a path part, a tag, a value of the
wrong JSON type. Ignoring it would silently weaken the check. Fields may be in any order, and a field never
appears twice. Every op may have a `note` field, a string that is ignored.

## 2. Values

### Integers

A JSON integer literal, with no fraction or exponent, parsed exactly over its whole range: `0` to 2⁶⁴−1 for an
unsigned value (`uint`, `size`, `offset`, `seek`, a slot's `value`), −2⁶³ to 2⁶³−1 for a signed one (`int`,
indexes). Don't parse
through a double. Zig's `std.json` with `parse_numbers = false`, and Swift's `JSONDecoder` and
`JSONSerialization` on macOS 27, were all checked to be exact at both ends of these ranges.

Indexes are `i65` in Zig, but scripts only go as far as `i64`. Anything beyond that is `KeyNotFound` on any
real list anyway.

### Bytes

Either form, wherever this document says *bytes*:

- a JSON string: the UTF-8 encoding of the string after JSON unescaping. Nothing is normalized: `"é"` is
  the 3 bytes `65 cc 81`, not the 2 bytes of `é`. In Swift, take `.utf8` of the string, and compare bytes rather
  than `String`s, because `String` equality treats those two as equal.
- `{"hex": "610062"}`: an even number of lowercase hex digits, the bytes in order. The empty string is allowed.

Whether a value ends up inline in its slot (`short_bytes`) or in a record of its own (`bytes`) is the engine's
decision, based on the value's bytes and whether it has a format tag. A script can't ask for either.

### Format tags

[Bytes](#bytes), exactly 2. `"bi"` and `{"hex": "6269"}` are the same tag. Leaving it out means no tag. `{"hex":
"0000"}` is a tag like any other, and sets the slot's `full` flag.

### Hashes

Exactly one of:

- `{"hex": "..."}`: exactly `2 * hash_size` lowercase hex digits.
- `{"sha1": BYTES}`: the SHA-1 digest of those [bytes](#bytes). Only valid when `hash_size` is 20.

The digits, or the digest, are **the hash's bytes in the order they appear on disk**, at the start of the key-value
pair. Zig reads them into its `HashInt` as a big-endian integer (`std.mem.readInt(HashInt, &hash, .big)`) and
writes them back the same way. A runner that passes hashes as bytes passes them along unchanged.

So the trie is walked from the **end** of the written hash, low nibble first. `{"sha1": "foo"}` is
`0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33`, whose last byte is `33`, so level 0 uses slot 3, level 1 uses slot
3, and level 2 uses slot `a`, from the `8a` before it.

### Floats

Exactly 16 hex digits: the IEEE 754 bit pattern, most significant first, which is also what's on disk.
`"400921fb54442d18"` is π. There is no decimal form, so nothing is rounded and NaN payloads survive. Compare
floats by their bits.

### Slots

Anywhere a slot is given in a path, one of:

- `{"var": NAME}`: the slot [bound](#4-names) to `NAME`, which may hold null.
- `{"tag": NAME, "value": 77, "full": false}`: a literal slot. `tag` is a name from the `Tag` enum: `none`,
  `index`, `array_list`, `linked_array_list`, `hash_map`, `kv_pair`, `bytes`, `short_bytes`, `uint`, `int`,
  `float`, `hash_set`, `counted_hash_map`, `counted_hash_set`, `sorted_map`, `sorted_set`, `sorted_kv_pair`.
  `value` defaults to 0 and `full` to false. It is passed as it is, whatever it means.
- `null`: no slot. Only `{"write": {"slot": ...}}` accepts a null slot, being `?Slot` in Zig. A `{"var": NAME}`
  that holds null counts as `null`.

### Write data

`WriteableData`, with exactly one field:

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
| `{"linked_array_list_concat": {"list": SLOT}}` | `.linked_array_list_concat`. The slot can't be null |
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

Everything in a path, including `{"var": NAME}`, is evaluated once, before the call starts.

## 4. Names

A script has one table of names, with no scopes. A name is made of ASCII letters, digits and underscores, and
doesn't start with a digit. It stays bound for the rest of the script, until something binds it again, including
after the callback or transaction that bound it has ended. Each name holds one of:

- a read-write cursor,
- a read-only cursor,
- a slot, or null, from a slot-reading op,
- a null cursor, from a `read_path` that found nothing. Using one for anything is a script failure.

`root` is reserved and can't be bound. Each use of it means a new `db.rootCursor()`.

**Cursors are values.** Binding one copies it, and two names never alias. A cursor holds a position and a
**snapshot** of the slot at that position, and is only updated by what's done through that name:

- `write`, `write_if_empty` and `writer` update the cursor they are called on, as Zig's take `*Cursor`.
- `write_path` does not change the cursor it is called on. Its result is a new cursor, bound by `as`.
- `slot`, `count` and the `read_*` ops see the snapshot, however stale it is. `read_path` and `read_path_slot`
  also start from it.
- `write_path` starts by reading the slot at the cursor's position again, if it has one, so its result sees the
  present.

A root cursor is the exception: everything it does reads the root from the last commit, so it's never stale. That
means it doesn't see a transaction in progress either: `count` on a root list inside a callback gives the count
from before the transaction.

Using a read-only cursor where a read-write one is needed is a script failure, as these methods don't exist on
read-only cursors in Zig.

**What a kept cursor can do.** `write_path` returns a root cursor if its path ended at the root, as a lone
`hash_map_init` does, and every write through that cursor is a transaction of its own. Any other cursor from a
finished transaction can still be read. Writing through it fails with `ExpectedTxStart` between transactions.

Two uses have no defined result, and scripts must not contain them:

- Writing through a cursor kept from an earlier transaction, *during* a later one. Zig doesn't stop this, and the
  write lands on committed bytes, in place.
- Using a cursor from a transaction that was rolled back. What it points at is gone.

## 5. Ops

Every op is an object with an `op` field. An op can have `note`, and all of them except `fail` can have
`expect_error` ([section 7](#7-errors)). A name in `on` must hold a cursor, and optional fields marked `?` can be
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
| `fail` | | `return error.ScriptAbort`. Only valid in a callback | |
| `read_path` | `on`, `path`, `as?`, `expect_null?` | `on.readPath(path)` | `as`: a read-only cursor, or a null cursor |
| `read_path_slot` | `on`, `path`, `as?`, `expect_null?`, `expect?` | `on.readPathSlot(path)` | `as`: a slot, or null |
| `slot` | `on`, `as?`, `expect?` | `on.slot()` | `as`: a slot |
| `read_only` | `on`, `as` | `on.readOnly()` | `as`: a read-only cursor |
| `read_key_value_pair` | `on`, `key_as?`, `value_as?`, `expect_hash?` | `on.readKeyValuePair()` | `key_as`, `value_as`: cursors of the same kind as `on` |
| `read_uint` | `on`, `expect?` | `on.readUint()` | |
| `read_int` | `on`, `expect?` | `on.readInt()` | |
| `read_float` | `on`, `expect?` | `on.readFloat()` | |
| `read_bytes` | `on`, `expect?`, `expect_format_tag?` | `on.readBytesObjectAlloc(allocator, null)` | |
| `count` | `on`, `expect?` | `on.count()` | |

`write_path`, `write`, `write_if_empty`, `writer`, `freeze` and `read_only` need a read-write cursor. The others
take either kind.

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

**Expectations** are assertions on the result, for reads the file can't show:

| Field | Passes when |
|---|---|
| `expect` on `read_uint`, `read_int`, `count` | the integer is equal |
| `expect` on `read_float` | the bit pattern is equal ([floats](#floats)) |
| `expect` on `read_bytes` | the bytes are equal ([bytes](#bytes)) |
| `expect` on `slot`, `read_path_slot` | an object with any of `tag`, `value`, `full`: each given field is equal. It fails on a null slot |
| `expect_format_tag` | a [format tag](#format-tags) that is equal, or `null` for no tag. Left out, the tag isn't checked |
| `expect_null` | `true`: the result is null. `false`: it isn't. Left out, either is fine |
| `expect_hash` | a [hash](#hashes) that is equal. A sorted entry's hash is all zeros |

A failed expectation is a script failure ([section 10](#10-running-a-script)), not an engine error, so
`expect_error` can't catch it.

## 6. Callbacks

A `ctx` part or a `run_context` op is a Zig callback, `run(cursor: *Cursor(.read_write))`, which does this:

1. Bind `as` to `cursor.*`.
2. Run the `ops` in order.
3. If they all finished, assign `cursor.* = ` whatever `as` holds now, and return. It must hold a read-write cursor.
4. If an error is leaving the callback ([section 7](#7-errors)), return it.

Step 3 is what makes writes through the callback's cursor visible to the path that called it. `write` on `as`
updates it, and so does a `write_path` that binds its result to `as`, which is how Zig's `cursor.* = ...` is
written. A `write_path` through `as` with no `as` of its own changes the file but leaves the cursor as it was, so
the cursor the outer call returns holds the old slot.

The callback runs when the path reaches it, and only then. If an earlier part fails, it doesn't run. In a read
path, `ctx` fails with `WriteNotAllowed` without running. Ops inside a callback are evaluated when they run.

Callbacks nest to any depth. A callback's `as` can't be the name of a callback that is still running around it:
that's a script failure. It can be reused once that callback has ended, as `as` is an ordinary name. A cursor
kept in a callback can be written through from a callback nested in it, or after it has ended, for as long as the
transaction lasts.

## 7. Errors

An op has a **result**: it finishes, or it raises an engine error with a name. `expect_error` says which:

| `expect_error` | The op finishes | The op raises error E |
|---|---|---|
| given | script failure | If it names E, E is handled: nothing is bound, and the next op runs. Otherwise, script failure |
| left out, inside a callback | the next op runs | E leaves the callback: its remaining ops don't run, and the op that called the callback raises E, to which this table applies again |
| left out, at the top level | the next op runs | script failure |

This is `try`: an op with no `expect_error` passes the error upward, and an op with one catches it. A failed op
binds nothing, so names in `as` keep what they had.

**What gets undone** is the engine's decision, not the runner's:

- When an error leaves a transaction, meaning the top-level call on the root cursor fails, the engine truncates the
  file back to the last commit. The whole transaction is gone, and the next one starts from the same bytes.
- When a callback handles an error, **nothing is undone**. The path that failed may have written to the file and
  linked what it wrote into the tree, all of which stays, and gets committed with the rest. From
  `scripts/04-rollback.json`, inside a callback:

  ```json
  { "op": "write_path", "on": "m", "path": [{ "hash_map_get": { "value": { "sha1": "b" } } }, { "array_list_get": 0 }], "expect_error": "KeyNotFound" }
  ```

  `hash_map_get` creates the entry for `b`, then `array_list_get` fails. After the commit `b` exists with an empty
  value. A freeze, and the advance of `tx_start` by `linked_array_list_concat`, aren't undone either.

**Error names** are Zig's: `@errorName`, without `error.`. A second runner maps its own errors to these names.
The ones scripts expect:

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

`EndOfStream`, `InvalidEnumTag`, `InvalidBTreeNode`, `InvalidBTreeNodeKind`, `KeyOffsetExceeded`, `MaxShiftExceeded`
and `StreamTooLong` exist in the engine, but need a corrupt file or an undefined use (section 4) to reach, or a
call scripts can't make.

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

An op on a root cursor inside a transaction, with a non-empty path, raises `NestedTopLevelWrite`. So at most one
commit happens per top-level op, and an op inside a callback never commits.

The engine asks its random source for one 64-bit value per commit, and nowhere else (`lib.zig:916`). Creating
the database doesn't, because the file ID is given and the first commit's ID is 0.

## 9. The sidecar

`run` writes `<out.db>.sidecar.json` next to the database:

```json
{
  "format": "xitdb-sidecar/1",
  "file_id": "0011223344556677",
  "initial_size": 62,
  "file_size": 438,
  "ops": [
    {"committed_size": 438, "commit_id": "303585f7ed65083c"}
  ]
}
```

| Field | Meaning |
|---|---|
| `format` | exactly `"xitdb-sidecar/1"` |
| `file_id` | the script's file ID |
| `initial_size` | the committed size right after creating the database, always 62 |
| `file_size` | the size of the file after the last op, which is also the last `committed_size`. No bytes are left past it |
| `ops` | one entry per **top-level** op in the script, in the same order, including ops that are only reads |
| `ops[i].committed_size` | `db.committedSize()` after op `i` |
| `ops[i].commit_id` | 16 hex digits if op `i` committed, otherwise `null` |

The commit ID's digits are the 8 bytes of the trailer's commit ID field, in order. As a number, they are the
big-endian value of those bytes, which is what `randomU64` returns in Zig. The trailer is at `committed_size − 25`.

**To reproduce a file**, give the second implementation a random source that returns the non-null commit IDs in
order, one per call. At the end, none should be left. Then after each top-level op, check the committed size
against `ops[i].committed_size`, which finds the first op that went wrong, and at the end compare the whole file.
`src/detcheck.zig` shows that the commit IDs are all it takes: it writes one run's IDs into another run's file,
recomputes the checksums, and gets the first file back exactly.

The checksum is computed by the engine and isn't in the sidecar. It should come out equal by itself.

## 10. Running a script

```
run <script> <out.db> [--kind buffered_file|file|memory]
```

The Zig runner truncates `<out.db>`, runs the script, and writes the file and the sidecar. The default kind is
`buffered_file`. It exits with:

| Status | Meaning |
|---|---|
| 0 | the script ran to the end, and every expectation passed |
| 1 | **script failure**: an error nothing handled, a failed expectation, or a malformed script. The runner stops there, and the output files must not be used |
| 2 | wrong command line |

A script is checked as it runs, so an op that's never reached isn't checked.

A second runner reads a script and a sidecar, and has the same idea of a script failure. How it's started is up to
it, and it needn't write a sidecar.

**Storage kinds don't change the bytes.** `check.sh` holds every script in this repository to that, across all
three kinds, in debug and release builds. There's one known difference in behaviour: within a transaction, reading
a gap left by a `writer` that seeked past the end raises `EndOfStream` on `buffered_file` and gives zeros on the
other two. The committed bytes are the same in all three. Scripts must not read a gap before it's committed.

**Hash sizes above 32** have a limit in Zig. The depth counter in the trie code overflows if two keys share their
lowest 64 nibbles, which panics in debug builds. Scripts must not do that. Real hashes would need a 256-bit
collision.

## 11. Behaviour a runner must not fix

All of these look like mistakes and all of them are what Zig does. `tests/valid/path-api-edges.json` and
`tests/valid/every-construct.json` pin them down.

1. **A remove ends the path.** `hash_map_remove` and `sorted_map_remove` return without looking at the parts after
   them, with no error. A `write` after one does nothing, and a `ctx` after one doesn't run.
2. **`write_path` doesn't update the cursor it's called on** (section 4), so a callback that only uses `write_path`
   on its own cursor returns its old slot.
3. **A failed path keeps what it wrote** if the error is handled in a callback (section 7). For example,
   `{"sorted_map_get": {"key": "b"}}` followed by `{"write": ...}` fails with `CursorNotWriteable` after inserting
   `b`.
4. **`sorted_map_get_index` only works in a read path.** It's the one getter that fails with `WriteNotAllowed` in
   a write path.
5. **A sorted map's key can be written one way but not the other.** Through `{"sorted_map_get": {"key": ...}}` the
   cursor has no position, so writing fails with `CursorNotWriteable`. Through `read_key_value_pair` on a
   `{"sorted_map_get": {"kv_pair": ...}}` cursor, it has one, so writing works, and writing a different key would
   break the order. In a key-only entry there's no key slot to write to.
6. **Asking a set for a pair changes the entry.** `{"sorted_map_get": {"kv_pair": ...}}` in a write path moves a
   key-only entry into a `sorted_kv_pair`, even in a `sorted_set`.
7. **Writing `none` sets `full`, and keeps the value.** `{"write": {"slot": {"tag": "none", "value": 5}}}` writes
   tag `none`, `full` set, value 5.
8. **Nothing stops a read of a stale snapshot** (section 4). `read_uint` on a cursor whose slot has since been
   written reports `UnexpectedTag` if the old slot wasn't a `uint`.

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

With file ID `0011223344556677`, hash ID `sha1`, hash size 20 and the commit ID `303585f7ed65083c` it makes 438
bytes, 376 of them after the new database's 62:

| Offset | Bytes | What |
|---|---|---|
| 0 | `78 69 74` `00` `00 01` `00 14` `73 68 61 31` `00 11 22 33 44 55 66 77` | database header |
| 20 | `02 00 00 00 00 00 00 00 47` `00 00 00 00 00 00 01 b6` | root header: root slot (`array_list` at 71), committed size 438 |
| 37 | 9 zero bytes, 8 zero bytes, `fd fb 75 cf 6f f9 eb 93` | trailer of the new database: empty root, commit ID 0, checksum |
| 62 | `02 00 00 00 00 00 00 00 47` | the transaction's scratch slot, holding the new root |
| 71 | `00 00 00 00 00 00 00 01` `00 00 00 00 00 00 00 57` | array list header: 1 element, index block at 87 |
| 87 | `04 00 00 00 00 00 00 00 e7`, then 135 zero bytes | index block. Slot 0 is the element: a `hash_map` at 231 |
| 231 | 27 zero bytes, `05 00 00 00 00 00 00 01 77`, 108 zero bytes | the map's index block. Slot 3 (the hash ends in `33`) is a `kv_pair` at 375 |
| 375 | `0b ee c7 b5 ea 3f 0f db c9 5d 0d d4 7f 3c 5b c2 75 da 8a 33` | the pair's hash |
| 395 | 9 zero bytes | the pair's key slot, empty |
| 404 | `08 00 00 00 00 00 00 00 2a` | the pair's value slot: `uint` 42 |
| 413 | `02 00 00 00 00 00 00 00 47` `30 35 85 f7 ed 65 08 3c` `3e dd da 5b f0 86 86 bc` | trailer: root slot, commit ID, checksum |

The checksums are CRC-64/XZ of file ID, trailer position, root slot and commit ID, as in `file-format.md`. Both of
these were recomputed with a separate implementation of the CRC.

The sidecar for this run is the one in section 9.

## 13. Not in this version

These are Zig API that scripts can't call yet. Adding reads later won't change the bytes any existing script
produces.

- Iterators (`iterator`, `iteratorFrom`, `iteratorFromIndex`) and `rank`.
- Streaming reads (`Cursor.reader`), and reads into a caller's buffer.
- A byte writer left open across other ops, which is the only way to reach `WriteFailed` and
  `UnexpectedWriterPosition`.
- Reopening a database, a file with bytes past its committed size, compaction, and replication.
