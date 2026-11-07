# What the port's agreed differences touch

After its parity gate, the Swift port adopts guards and fixes that the Zig original doesn't have
(`director/zig-findings.md`, D17, D18 and D19). This says which scripts rely on what each one changes, and what would
happen to each script. **All of it has been done**, apart from finding 23, which was deferred. The next section says what the
fixtures are now, and each section after it says why.

## How this was found

**The lists are generated.** `run --note-port-changes` prints a line for each place a script relies on one of these, and
`./impact.sh` fills in the lists below from every script in the repository. The number after a name is how many ops. The
gate fails if the lists aren't what the scripts do, so a new script that relies on one of these shows up here. A
`<name>--<commit>` script in `tests/from-other-zig` isn't listed, as it's a version of one that is, and the Zig at
`6b93af1` can't get to the end of it.

**Three of the changes were tried.** `./impact.sh --prototypes` makes findings 12, 17 and 23 in a scratch copy of Zig
and runs every script against it. Where this document says "the prototype", that's what ran, and everything else in a
"what happens" column is reasoned. Those results are from the scripts at `c88ae9f`, and from `deep-sorted-existing`, which came after and changes nothing in any of them. They aren't in the gate, as it's slow.

**A script not listed under a change doesn't rely on it.** It can run as it is, as far as that change goes.

## What can happen to a script

| | What it means |
|---|---|
| **Variant** | A copy of the script as `tests/port-variants/<name>--port`, where the op gets `expect_error` with the port's error, and whatever came after it is adjusted |
| **Only for Zig** | It's in `tests/zig-only.txt`, so it isn't a fixture, and goes on running on Zig |
| **`safe-*`** | A generated script that stops doing this, as `gen --port-safe` has a rule for it. The same seed gives another script |
| **Nothing** | |

**A variant still has an oracle.** Zig doesn't have these guards, so it can't run one alone. But a guard that refuses before it
writes anything leaves the file as if the op had never been there, and that's what `run --port` does, with the Zig engine for the
rest. That depends on the guard writing nothing, which the port's brief holds it to. It doesn't work for what changes what's
written and raises nothing, like finding 17, which needs a Zig with the change.

## What the fixtures are now

They're what the port has to do once it has its guards. `SCRIPT-FORMAT.md` section 11 says exactly what those do, and
`run --port` acts them out on the Zig engine, which is where the expected files come from. It dies on a write the port would
refuse, unless the script says so with `expect_error`. So a fixture can't rely on anything listed below without pinning it,
and the gate runs them all that way.

**A script that does what the port refuses isn't a fixture.** It goes on running on Zig, in the gate and `mutants.sh`, as
what Zig does hasn't changed. `tests/zig-only.txt` lists all 43, with the gate holding it to what `run --port` refuses. That's
34 of the 42 generated scripts, and these 9, each with a version of its own in `tests/port-variants`:

| Script | Its variant `<name>--port` | Expected file from |
|---|---|---|
| `04-rollback` | The transaction that used to commit after a failed op is poisoned, and rolled back. A new one shows that an op that failed before writing anything poisons nothing | `6b93af1` |
| `overwriting-committed-bytes` | Each write through a kept cursor raises `StaleCursor`, an init too, and nothing is overwritten. The writes that only skip an init part stay, as finding 13 hasn't changed. It also has a read and a write through a cursor from a rolled-back transaction | `6b93af1` |
| `path-api-edges` | The part after a remove raises `PathPartMustBeAtEnd`. What poisons is in a transaction of its own, so that the other corners go on committing. `write_if_empty` goes by the slot as it is now | `185af01` |
| `path-api-edges-sorted` | The same | `6b93af1` |
| `every-construct-linked` | What a concat gives back is fresh, and the cursors from before it raise `StaleCursor`, on each kind of write. They can still be read, and an init goes on from there | `185af01` |
| `every-construct-sorted` | Writing a key through a pair raises `CursorNotWriteable` | `6b93af1` |
| `recovery-open-errors` | `UntrustedRootHeader` where the root header can't be trusted, and then `recover`, down to losing the last commit and going on from there | `6b93af1` |
| `replicate-bad-trailer`, `replicate-failed-first-sync` | The same, on a replica | `6b93af1` |

"From `6b93af1`" means the gate runs it, and that `185af01` gives the same bytes. Recovering leaves what Zig writes for the
script without the damage: for `recovery-open-errors`, that was compared with a script of only what came after, and only the
last trailer's commit ID and checksum differ.

`several-databases` had one write after a `db_freeze` that didn't need to be there, so it comes before it now. It's the
same bytes, and valid on both. **`write-if-empty-emptied-slot`** and `write-if-empty-unreachable` stay as they were.

**`gen-fixed.sh` also writes the 42 seeds again with `--port-safe`**, as `safe-*`. They're fixtures, and valid on both.

**What the port fails at the start of its brief**, before any of this is in it: the 9 variants, and
`write-if-empty-emptied-slot`. Those are what fail without `--port` on `6b93af1` too, and everything else passes both ways.

## Summary

| Item | What the port changes | Hand-written scripts | Generated | Mostly |
|---|---|---|---|---|
| [1](#finding-1-a-write-through-a-cursor-from-a-finished-transaction) | A write through a cursor from a finished transaction is an error | 1 and a reproduction that write today, and 8 that raise today | 11 | Variant, `safe-*`, and nothing for those that raise |
| [2](#finding-2-a-sorted-key-through-a-pair) | A sorted key can't be written through a pair | 1 | 0 | Variant |
| [3](#finding-3-a-structural-slot-as-a-value) | `write` rejects structural tags | 0, and 3 that `run` refuses | 0 | Nothing |
| [12](#finding-12-parts-after-a-remove) | Parts after a remove are an error | 2 | 0 | Variant, with an error that already exists |
| [16](#finding-16-a-failed-op-that-left-something-behind) | A failed op that wrote something poisons its transaction | 3 | 12 | Variant, `safe-*` |
| [17](#finding-17-write_if_empty-and-the-snapshot) | `write_if_empty` goes by the slot as it is now | 2 | 4 | Done: regenerated from `185af01` |
| [22](#finding-22-the-concat) | A concat freezes after its join | 1 changes | 1 changes | Variant, from `185af01` |
| [23](#finding-23-a-cursors-freeze) | A freeze holds for every cursor | 2 of 6 change, in the prototype | 2 of 17 change | Deferred, so nothing happens |
| [D18](#d18-refusing-a-write-from-before-a-freeze) | A write from before a freeze is refused | 2, and 1 reproduction | 31 | Variant, `safe-*`. An init and a read through such a cursor go on working |
| [D19](#d19-opening-a-file-whose-root-header-cant-be-trusted) | A file whose root header can't be trusted raises an error, until `recover` is called | 3, and none of the 3 failing ones | 0 | Variant, with `recover` |

## A generator that keeps off all of this

`gen --port-safe` writes scripts that do none of what's listed here, so Zig's result for one is what the port has to give, on
any seed, before or after these changes go in. The scripts already committed don't change, and neither does what `gen` writes
without it. `PORT_SAFE=yes ./gen-live.sh <how many>` holds each script to that with `run --note-port-changes`, and the gate
runs 20. The notes that stay allowed are `18-init`, `18-reads`, `18-reads-earlier` and `1-raises`, which stay valid on the port.

| Item | What it does instead |
|---|---|
| 1 | No write through a cursor from an earlier transaction |
| 2, 3, 12, D19 | `gen` doesn't do these anyway |
| 16 | An error from an op that wrote something goes up, and rolls the transaction back |
| 17 | `write_if_empty` only where the snapshot and the slot agree about being empty |
| 22 | No concat |
| 23 | No cursor's freeze |
| D18 | A write through a cursor from before a freeze only after an init through it. Reads through one go on |

**What it costs.** It has no concat, no cursor's freeze, and nothing that writes into committed bytes, so also no skipped init,
as a transaction that has done that can't be rolled back (`SCRIPT-FORMAT.md` section 10). A path that doesn't fit is always
one that can't. The committed fixtures go on covering all of those. Over 300 seeds, the other ops come to about the same
number as without it.

**What was measured.** 2000 fresh seeds went through `gen-live.sh` with no failures. 1000 scripts from it have the same bytes on
Zig at `6b93af1` and at `185af01`, which has the fixes for findings 2, 8, 9, 17 and 22. Of 1000 scripts from the same seeds
without it, 55 have different bytes there, and 87 fail, some of them only because a size that `gen` wrote down has moved. This
can only say what Zig does and what `run` notes. The port's guards don't exist yet, so nothing here has run on them.

## Finding 1: a write through a cursor from a finished transaction

The port makes this an error. There are two cases, because of what Zig does today.

**It writes into committed bytes**, when another transaction is going:

<!-- list 1-writes -->
- `tests/dump`: dangling (1)
- `tests/generated`: compact-204 (1), gen-10 (1), gen-16 (1), gen-3 (1), gen-4 (1), gen-5 (1), gen-7 (1), gen-9 (2), reads-108 (1), reads-109 (1), reads-110 (1)
- `tests/valid`: overwriting-committed-bytes (2)
<!-- end -->

| Script | What happens |
|---|---|
| `overwriting-committed-bytes` | Variant. It exists to pin this, so its writes get `StaleCursor`, and the reads after them that expected the overwritten values changed by hand. The part that skips an init part stays, as finding 13 is unchanged |
| `overwriting-committed-bytes-linked`, `-sorted` | Nothing. These only skip an init part, which is finding 13. `zig-findings.md` cites `overwriting-committed-bytes*` under finding 1, and it's only the first |
| `tests/dump/dangling` | Nothing. It's there to show `dump` a dangling slot, which is finding 24, and it's only ever run on Zig |
| the generated scripts | Only for Zig. `gen --port-safe` doesn't use a kept cursor from an earlier transaction, so `safe-*` is valid on both |

**It raises `ExpectedTxStart`**, when no transaction is going:

<!-- list 1-raises -->
- `scripts`: 02-nested-collections (2), 05-non-list-root (1)
- `tests/failing`: unhandled-error (1), wrong-error-name (1)
- `tests/valid`: every-construct (1), path-api-edges (1), replicate-roots (1), several-databases (2)
<!-- end -->

These are errors already, and the port keeps the name `ExpectedTxStart` for this case (D22), so **nothing happens to any of
them**. `StaleCursor` is only for the first case.

## Finding 2: a sorted key through a pair

<!-- list 2 -->
- `tests/valid`: every-construct-sorted (1)
<!-- end -->

**Variant**, with `expect_error: CursorNotWriteable` on that one op and nothing else changed. It raises before writing, so it
has the same bytes under `run --port` on `6b93af1` as on `185af01`, whose engine raises the same error. No other script does
this: it's also the only one that fails on that branch for this reason.

## Finding 3: a structural slot as a value

<!-- list 3 -->
- `tests/invalid`: write-kv-pair-slot (1), write-kv-pair-slot-over-another-keys-entry (1), write-sorted-kv-pair-slot (1)
<!-- end -->

**Nothing.** `run` refuses these before they reach the engine, so no valid script does this, and a second runner never sees
them. The port's own tests are what will show its error.

## Finding 12: parts after a remove

<!-- list 12 -->
- `tests/valid`: path-api-edges (1), path-api-edges-sorted (1)
<!-- end -->

**Variant**, with `PathPartMustBeAtEnd`, which already exists. The prototype fails exactly these two scripts, and nothing else
differs. It raises before removing anything, so the reads after it changed by hand too. The port has to raise before it
removes, or the expected files don't hold.

## Finding 16: a failed op that left something behind

The port poisons the transaction, which can then no longer commit. A script is listed if an op in a callback failed, its
error was handled, the file was different afterwards (compared byte for byte, on the memory kind), and the transaction then
committed. An op that failed before writing anything isn't listed, as it wouldn't poison anything.

<!-- list 16 -->
- `scripts`: 04-rollback (2)
- `tests/generated`: compact-203 (1), compact-205 (1), compact-206 (1), gen-12 (1), gen-16 (1), gen-17 (1), gen-3 (1), gen-9 (2), reads-105 (2), reads-107 (1), reads-110 (1), replica-305 (2)
- `tests/valid`: path-api-edges (1), path-api-edges-sorted (1)
<!-- end -->

| Script | What happens |
|---|---|
| `04-rollback`, `path-api-edges`, `path-api-edges-sorted` | Variant. The top-level op gets the new error, and what the rest of the script expects to find changed by hand, as none of that transaction is there. `04-rollback` exists to pin this, and section 7 of `SCRIPT-FORMAT.md` quotes it. In the other two, what poisons moved to a transaction of its own, so that the other corners go on committing |
| the generated scripts | Only for Zig. `gen --port-safe` tells in the same way whether a failed op left anything, and then lets the error go up rather than handling it |

The oracle for a variant is Zig on the same script with that transaction made to fail, and that's what `run --port` does: it
rolls back when the outermost callback returns, and that takes no commit ID.

**What "written something" means was measured, not reasoned.** `run --port` goes by whether a byte of the file changed. With a
counter in a copy of the engine, 79 handled failures in the fixtures issued a write and changed no byte, in 34 fixtures, because an
init always writes its slot back. So the port's definition leaves that out (`SCRIPT-FORMAT.md` section 11), and then the two agree
on all 121 passing fixtures on `185af01`. Of 37,122 handled failures in fresh scripts, 1 still differs, as a sorted get writes its
header back too. A port may go either way on that shape, and no fixture has it.

## Finding 17: `write_if_empty` and the snapshot

The port goes by the slot as it is now. Nothing raises an error, but what's written changes, so **no script can show this
without a Zig that has the change**, which is `185af01` on the `xitdb` session's branch. There are two directions:

Where the snapshot is empty and the slot isn't, so Zig at `6b93af1` overwrites a value it can't see, and the port leaves it:

<!-- list 17-overwrites -->
- `tests/from-other-zig`: write-if-empty-emptied-slot (1)
- `tests/generated`: compact-203 (1), gen-16 (1), reads-101 (1), reads-107 (1)
- `tests/valid`: path-api-edges (1)
<!-- end -->

Where the snapshot has something and the slot is empty, so Zig at `6b93af1` holds back, and the port writes:

<!-- list 17-holds-back -->
- `tests/from-other-zig`: write-if-empty-emptied-slot (3)
<!-- end -->

**This has been done.** `tests/zig-commits.txt` says which expected files come from `185af01`. The prototype's prediction held
for every script. The fixtures have the first direction in these two scripts, and in no generated one, as `gen --port-safe` keeps
off it:

| Script | On `185af01` | What happened |
|---|---|---|
| `compact-203`, `gen-16`, `reads-107`, `reads-101` | different bytes for the first three, and the same for the last | Only for Zig, as each has stale writes too |
| `path-api-edges` | fails at the read after the write, which expects the overwritten value | Only for Zig, as the gate and `mutants.sh` run it on `6b93af1`. `path-api-edges--port` has that read and the note before it turned round |
| `write-if-empty-emptied-slot` | new | The second direction, in `tests/from-other-zig` as it fails on `6b93af1` |
| `write-if-empty-unreachable` | new | Where it looks like the second direction and isn't, in `tests/valid` as it has the same bytes on both |

**The second direction can't be reached through the wrappers alone in one transaction.** A remove empties the map's own
slot for the key, and leaves the pair as it was. So a value cursor from `putCursor` points at something that's unreachable
and not empty, and `put(k, .{ .slot = null })` is no route, since a written none has `full` set, which isn't empty. It takes
a `kv_pair` cursor from the path API, which points at the map's slot. `src/test.zig` on that branch then puts the pair back
with the slot it captured. **A script can't do that**: `run` refuses to write a `kv_pair` slot (finding 3), and the port's
`write` rejects one. So `write-if-empty-emptied-slot` writes a none, which leaves the map working, and a uint, which shows
that it wrote, as reading that key then raises `UnexpectedTag`.

**A cursor from a rolled-back transaction** has a position past the end of the file. At `185af01`, `write_if_empty` through
one raises the reader's error, where it used to do nothing if the snapshot had something. No script here can do that,
because `run` refuses every use of such a cursor (`tests/invalid/cursor-from-rolled-back-transaction`, section 10). So it
isn't in the lists under finding 1 or finding 24, and nothing happens to any script. The port's guard for reads through a
cursor from a transaction that didn't commit (D22) is what will report it there.

## Finding 22: the concat

The port freezes after the join, as the fix branch does. Every script with a concat:

<!-- list 22 -->
- `tests/generated`: compact-202 (1), compact-203 (1), compact-205 (4), compact-206 (3), gen-1 (2), gen-10 (2), gen-11 (3), gen-13 (4), gen-16 (1), gen-17 (4), gen-4 (2), gen-7 (2), gen-8 (2), reads-101 (1), reads-103 (4), reads-106 (1), reads-112 (1), replica-302 (2), replica-304 (1), replica-305 (2)
- `tests/undefined`: concat-stale-slot (2)
- `tests/valid`: deep-linked (1), every-construct-linked (2)
<!-- end -->

Only two have different bytes on `d6f3fee`, and on `185af01`, which has the same fix. They're only for Zig now, because of
stale writes. `every-construct-linked--port` has a concat with its expected file from `185af01`, and `compact-205` has no
variant:

| Script | Where it starts | Why | What changes |
|---|---|---|---|
| `every-construct-linked` | the first write after its concat | The join's new leaf is older than the freeze now, so that write copies it rather than rewriting it | 146 bytes longer at that commit, which is one leaf (2 + 16 × 9). The commit IDs and everything else follow from that |
| `compact-205` | top-level op 27, at its callback's op 66, the first write after the concat at op 53. It writes through `{"linked_array_list_get": 20}` | The same, but the node concerned is the new root that the join made. The difference is exactly one branch node, so the leaf under it comes out the same on both | 274 bytes longer, from that op to the end of `main`, which is one branch node (2 + 16 × 17). **The target of its compaction is the same**, apart from its commit ID and checksum, as compaction goes by what's there and not where. So only `main`'s expected file changes |

The other scripts in the list have the same bytes on `d6f3fee`, so nothing happens to them. That's measured, by
`second-zig.sh`. I haven't gone through why for each of them.

**`gen` writes three scripts differently on `d6f3fee`**: `reads-101`, `reads-104` and `reads-110`. That has nothing to do
with the concat, and their files are the same. On that branch a sorted pair's key cursor has no position (the fix for
finding 2), so `gen` thinks a stream from it isn't allowed and leaves it out, and its reads go differently from there. The
committed scripts still pass there, and they stay as they are, as the README says.

**`tests/undefined/expected.txt` changes**, for 11 of its 19 cases, once the fixtures follow: `second-zig.sh` lists them.
None of them is a fixture.

## Finding 23: a cursor's freeze

**Deferred**, so nothing happens: a cursor's freeze isn't a freeze for the guard, and `gen --port-safe` keeps off it in case that
changes. `zig-findings.md` says a fix makes a cursor's freeze equivalent to `Database.freeze`, or needs another design. Every
script with a cursor's freeze:

<!-- list 23 -->
- `scripts`: 03-clone-and-freeze (1)
- `tests/generated`: compact-201 (1), compact-203 (3), compact-205 (2), gen-10 (2), gen-12 (1), gen-13 (1), gen-17 (2), gen-2 (2), gen-3 (1), gen-6 (1), gen-7 (1), reads-101 (2), reads-102 (1), reads-103 (2), reads-108 (1), replica-302 (2), replica-305 (2)
- `tests/undefined`: frozen-clone-linked-append (1), frozen-clone-linked-read (1), frozen-clone-sorted-read (1)
- `tests/valid`: deep-linked (1), deep-sorted (1), deep-sorted-existing (1), deep-tries (2), path-api-edges (3)
<!-- end -->

The prototype made a cursor's freeze a freeze of the database, as the simplest version of that:

| Script | In the prototype |
|---|---|
| `gen-3`, `deep-tries`, `path-api-edges` | different bytes |
| `compact-205` | fails at a read that finds nothing. That looks like the lost write of section F in `zig-findings.md`, through a cursor made before the freeze, which D18 would turn into an error, though I haven't traced it |
| the other 19 fixtures in the list | the same bytes |

So under that design, most of these don't change. The three in `tests/undefined` weren't part of this. They go from a crash
to an error on `d6f3fee` already, by the checks in option B.

## D18: refusing a write from before a freeze

The port refuses a write through a cursor made before the last freeze, whether that's `db_freeze` or a concat, with a concat
refreshing the wrapper that called it. It also gets option B, which is errors in place of traps, and Swift handles that
resolve themselves. B and the handles don't touch any script.

These write through a cursor made before a freeze in the same transaction, other than with a path that begins with an init part:

<!-- list 18-other -->
- `tests/generated`: compact-201 (1), compact-202 (4), compact-203 (2), compact-205 (1), compact-206 (1), gen-1 (1), gen-10 (3), gen-12 (5), gen-13 (2), gen-14 (8), gen-17 (4), gen-18 (8), gen-2 (3), gen-3 (3), gen-4 (1), gen-6 (1), gen-7 (4), gen-8 (1), reads-101 (2), reads-102 (3), reads-103 (2), reads-104 (1), reads-105 (2), reads-107 (2), reads-109 (4), reads-110 (5), replica-302 (2), replica-303 (2), replica-305 (3)
- `tests/valid`: every-construct-linked (11)
<!-- end -->

| Script | What happens |
|---|---|
| `every-construct-linked` | Variant, which pins the guard on each kind of write |
| `several-databases` | Its one write through `e` now comes before the `db_freeze`, with the same bytes |
| `tests/undefined/concat-stale-slot` | Nothing. It's a reproduction, and only ever run on Zig |
| the generated scripts | Only for Zig. `gen --port-safe` treats every cursor from before a freeze as gone for a write, other than with an init, and fine for a read |

And these write through such a cursor with a path that begins with an init part, which is how `Database.freeze`'s comment says to carry on:

<!-- list 18-init -->
- `scripts`: 03-clone-and-freeze (1)
- `tests/generated`: compact-201 (46), compact-202 (9), compact-203 (11), compact-205 (71), compact-206 (7), gen-1 (4), gen-10 (12), gen-11 (3), gen-12 (2), gen-13 (55), gen-15 (2), gen-16 (3), gen-17 (16), gen-18 (2), gen-2 (96), gen-3 (82), gen-4 (4), gen-5 (4), gen-7 (11), gen-8 (47), gen-9 (2), reads-101 (49), reads-102 (10), reads-103 (9), reads-104 (8), reads-105 (6), reads-106 (3), reads-107 (5), reads-108 (4), reads-110 (9), reads-111 (2), reads-112 (5), replica-302 (13), replica-303 (48), replica-304 (2), replica-305 (95), replica-306 (42), safe-1 (6), safe-10 (3), safe-12 (2), safe-13 (4), safe-15 (3), safe-17 (5), safe-2 (7), safe-3 (4), safe-4 (6), safe-5 (5), safe-6 (4), safe-7 (2), safe-8 (3), safe-9 (3), safe-compact-201 (5), safe-compact-202 (3), safe-compact-203 (4), safe-compact-205 (3), safe-reads-101 (4), safe-reads-102 (3), safe-reads-103 (3), safe-reads-104 (2), safe-reads-105 (2), safe-reads-106 (5), safe-reads-107 (4), safe-reads-108 (6), safe-reads-110 (2), safe-reads-111 (5), safe-replica-301 (2), safe-replica-302 (2), safe-replica-303 (4), safe-replica-304 (6), safe-replica-305 (4), safe-replica-306 (2)
- `tests/undefined`: concat-stale-slot (3)
- `tests/valid`: deep-linked (1), deep-sorted (1), deep-sorted-existing (1), deep-tries (1)
<!-- end -->

**These go on working** (D22). That init writes to the cursor's slot, which is from before the freeze, so a guard that went
by the position of what's being written would refuse it. Inside a callback, there's no other way on: the callback's cursor
is the only way to the moment, and a write on a root cursor raises `NestedTopLevelWrite`. So the guard goes by when the
cursor was made, and lets an init through. What follows the init in the path goes through what it made, so that's allowed too,
and it's safe, as that's the same as the init and then a write through its result. The exception is a cursor from an earlier
transaction: an init through one would rewrite a slot that's committed, which is finding 1, so that's refused.

**A read through such a cursor stays allowed too**, as a snapshot read (D22, as narrowed). These do that in the same
transaction, so they're what hold the port to it:

<!-- list 18-reads -->
- `tests/generated`: compact-201 (1), compact-203 (2), compact-205 (1), gen-10 (4), gen-12 (1), gen-13 (2), gen-14 (2), gen-17 (7), gen-18 (2), gen-2 (2), gen-3 (5), gen-8 (2), reads-101 (4), reads-103 (3), reads-104 (6), reads-105 (2), reads-108 (1), reads-109 (2), reads-110 (4), replica-302 (2), replica-303 (1), replica-305 (3), replica-306 (1), safe-14 (1), safe-3 (1), safe-compact-201 (1), safe-reads-101 (1), safe-reads-103 (3), safe-reads-104 (3), safe-reads-106 (4), safe-reads-110 (2), safe-replica-306 (1)
- `tests/undefined`: concat-stale-slot (1)
- `tests/valid`: every-construct-linked (2)
<!-- end -->

And these do it through a cursor from an earlier transaction that committed, with a freeze since:

<!-- list 18-reads-earlier -->
- none
<!-- end -->

That's safe **because of the guard on writes**. The crash after a concat was a read through a cursor from before a freeze,
whose tree had been rewritten under it. With stale writes refused, nothing rewrites those bytes, so such a read can be
stale, and never garbage. A `slot` isn't counted, as it goes by the snapshot and not the file. A read is only refused through
a cursor from a transaction that didn't commit, which no script can do, as `run` refuses that.

## D19: opening a file whose root header can't be trusted

The port refuses to open such a file, with `UntrustedRootHeader`, and a separate call, `recover`, goes back to the last trailer
whose checksum verifies (D22). So nothing is dropped except by that call. Every `reopen` that raises `InvalidDatabase` or
`TruncatedDatabase`:

<!-- list 19 -->
- `tests/failing`: op-after-failed-reopen (1), reopen-error-not-handled (1), reopen-wrong-error (1)
- `tests/valid`: recovery-open-errors (5), replicate-bad-trailer (1), replicate-failed-first-sync (1)
<!-- end -->

| Script, and what its `reopen` meets | Zig | The port |
|---|---|---|
| `recovery-open-errors`: a bad magic number | `InvalidDatabase` | The same error, as this isn't a database |
| `recovery-open-errors`: a committed size smaller than a new database, past the end of the file, or that doesn't end at a trailer | `InvalidDatabase`, `TruncatedDatabase`, `InvalidDatabase` | `UntrustedRootHeader` |
| `recovery-open-errors`: a changed root slot in the last trailer | `InvalidDatabase` | `UntrustedRootHeader`, and `recover` loses that commit |
| `replicate-bad-trailer`: a last trailer with its commit ID and checksum overwritten | `InvalidDatabase` | The same, and `recover` goes back to 62 |
| `replicate-failed-first-sync`: a file a byte short of what its root header says, after a failed sync | `TruncatedDatabase` | The same, and `recover` goes back to 62 |
| `op-after-failed-reopen`, `reopen-error-not-handled`, `reopen-wrong-error` | `InvalidDatabase`, as all three have a bad magic number | The same error, so they still fail |

**The variants of those three** expect the error, then `recover`, then the reads. A `reopen` writes nothing, so that's the same
as in Zig. `recover` isn't in Zig, so `run --port` does it itself, on the file's bytes. What it leaves is exactly a file cut off
at that trailer, with a root header that says so, and that's what the port's has to leave.

`recovery-torn-root-slot` isn't affected, as the root slot in the header is never read.

## What this doesn't cover

- **Finding 24** goes when finding 1's guard comes in, except by the internal path API. `tests/dump/dangling` is the only
  script that does this, and `gen` keeps away from it.
- **The fixes the port already has**, which are 8, 9, 21 and 26, are in `tests/port-differs/`, and no valid script relies on
  them. Findings 10, 11 and 15 are the same: `run` and `check.sh` keep them out of the scripts.
- **The notes go by what a script does, not what it means.** A script is listed if it does the thing, even if it makes no
  difference to its bytes, like `reads-101`. And "a cursor made before a freeze" is by name: two names for one slot count
  separately.
- **`run --port` isn't the port.** It says what the guards should do, and the port's own runner is what shows that they do.
