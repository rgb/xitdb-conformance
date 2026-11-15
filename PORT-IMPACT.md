# What the port's agreed differences touch

After its parity gate, the Swift port adopts guards and fixes that the Zig original doesn't have
(`director/zig-findings.md`, D17, D18, D19 and D22). This says which scripts rely on what each one changes, and what would
happen to each script. **All of it has been done**, apart from finding 23, which was deferred. The next section says what the
fixtures are now, and each section after it says why.

## How this was found

**The lists are generated.** `run --note-port-changes` prints a line for each place a script relies on one of these, and
`./impact.sh` fills in the lists below from every script in the repository. The number after a name is how many ops. The
gate fails if the lists aren't what the scripts do, so a new script that relies on one of these shows up here. A
`<name>--<commit>` script in `tests/from-other-zig` isn't listed, as it's a version of one that is, and the Zig at
`89da8e7` can't get to the end of it.

**Three of the changes were tried.** `./impact.sh --prototypes` makes findings 12, 17 and 23 in a scratch copy of Zig
and runs every script against it. Where this document says "the prototype", that's what ran, and everything else in a
"what happens" column is reasoned. Those results are from the scripts at `5b3d5b6`, and from `deep-sorted-existing`, which came after and changes nothing in any of them. They aren't in the gate, as it's slow.
They ran on Zig at `6b93af1`, and haven't been run again since the move to `89da8e7`, so they aren't current.

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
what Zig does hasn't changed. `tests/zig-only.txt` lists all 47, with the gate holding it to what `run --port` refuses. That's
33 of the 42 generated scripts, and these 14, each with a version of its own in `tests/port-variants`:

| Script | Its variant `<name>--port` | Expected file from |
|---|---|---|
| `04-rollback` | The transaction that used to commit after a failed op is poisoned, and rolled back. A new one shows that an op that failed before writing anything poisons nothing | `89da8e7` |
| `overwriting-committed-bytes` | Each write through a kept cursor raises `StaleCursor`, an init too, and nothing is overwritten. The writes that only skip an init part raise `ImmutableBytes` (D24): the list's through a fresh cursor, with nothing written before them, and the map's in a transaction of its own, which it poisons, as the get that adds a key writes the entry first. The earlier moment is as it was. It also has a read and a write through a cursor from a rolled-back transaction, and ends with a write from before a `db_freeze` | `89da8e7` |
| `path-api-edges` | The part after a remove raises `PathPartMustBeAtEnd`. What poisons is in a transaction of its own, so that the other corners go on committing. `write_if_empty` goes by the slot as it is now | `bd6abc3` |
| `path-api-edges-sorted` | The same | `89da8e7` |
| `every-construct-linked` | What a concat gives back counts as made before it, so it and the cursors from before it raise `StaleCursor`, on each kind of write, an init included. They can still be read. The way on is an init through the transaction's body, and finding 22's pin goes that way | `bd6abc3` |
| `every-construct-sorted` | Writing a key through a pair raises `CursorNotWriteable` | `89da8e7` |
| `recovery-open-errors`, `recovery-open-errors-version-1` | `UntrustedRootHeader` where the root header can't be trusted, and then `recover`, down to losing the last commit and going on from there, in version 2 and on a version 1 file | `89da8e7` |
| `replicate-bad-trailer` | The same, on a replica | `89da8e7` |
| `compact-roots` | The two compactions of a history with no last moment raise `EmptyLastMoment`, and so does one into a target with something in it. Written, the last moment compacts. Since `89da8e7` one appended and never written is a moment set to nothing, which compacts, and a version 1 history whose last slot is truly empty is refused | `89da8e7` |
| `held-init-after-freeze`, `held-init-after-root-copy` | Each init through a cursor held from before a freeze raises `StaleCursor` (D24), and the way on is from the transaction's body or through a cursor made from it since the freeze. Nothing is lost, and the clone is as it was | `89da8e7` |
| `overwriting-committed-bytes-linked`, `overwriting-committed-bytes-sorted` | The write that skips an init part raises `ImmutableBytes`. Through a fresh cursor at the committed collection nothing is written before it, and the same write with the init goes into a copy. Through the moment's map, as in the original, the get copies first, so the transaction is poisoned and rolled back | `89da8e7` |

"From `89da8e7`" means the gate runs it, and that the fixes branch at `bd6abc3` gives the same bytes. Recovering leaves what Zig writes for the
script without the damage: for `recovery-open-errors`, that was compared with a script of only what came after, and only the
last trailer's commit ID and checksum differ.

**Six scripts only the port can run** are in `tests/port-variants` too. What they do is an undefined use in Zig, or the port's own
`recover`, so there's no Zig script to make a variant of, and their oracle is Zig on the same script without what the port refuses,
or `run --port`'s recovery. That was compared on each kind, and each is the same bytes at `bd6abc3`. They're there so that `guard-mutants.sh` finds every guard it gets wrong
noticed by two fixtures, at least:

| Script | What it pins |
|---|---|
| `write-kv-pair-slot--port`, `write-sorted-kv-pair-slot--port` | Every way to write a structural slot raises `StructuralSlot` (finding 3), apart from `write` and `write_path` below the root with no transaction going, where `ExpectedTxStart` comes first. They're versions of the scripts with those names in `tests/invalid`. The sorted one also writes a key through a pair by each way to write, the byte writer included |
| `rolled-back-reads--port` | Every way to read through what a rolled-back transaction made: a cursor, a read-only cursor, a view made before or after the rollback, an iterator through one, and `next` on one made in it |
| `stale-cursors--port` | Every way to write through each kind of stale cursor: from an earlier transaction, from before a `db_freeze`, from before a concat, and from a rolled-back transaction. And the reads, the init and the concat's result that stay valid |
| `compact-sliced-history--port` | A list root sliced to nothing, as `gen` found, and a version 1 list root whose only element is truly empty (finding 28). One whose last element was appended in a callback that wrote nothing compacts since `89da8e7` |
| `recover-without-first-commit--port` | `recover` on a database without a first commit, in both versions: a file cut off during its creation, and a full copy that didn't finish, which it scans as any other (the director's ruling on conformance-09) |

`every-construct-sorted--port` also tries the byte writer on a key through a pair, and `overwriting-committed-bytes--port` now
ends with a write through a cursor from before a `db_freeze`. `body-write-after-freeze--port` is a variant of a script that's
valid on both, `body-write-after-freeze`, with what stays refused through the transaction's body after a freeze put in (D24
item 3).

`several-databases` had one write after a `db_freeze` that didn't need to be there, so it comes before it now. It's the
same bytes, and valid on both. **`write-if-empty-emptied-slot`** and `write-if-empty-unreachable` stay as they were.

**`gen-fixed.sh` also writes the 42 seeds again with `--port-safe`**, as `safe-*`. They're fixtures, and valid on both.

**What the port fails at the start of its brief**, before any of this is in it: the 14 variants, and
`write-if-empty-emptied-slot`. Those are what fail without `--port` on the original too, and everything else passes both ways.

## Summary

| Item | What the port changes | Hand-written scripts | Generated | Mostly |
|---|---|---|---|---|
| [1](#finding-1-a-write-through-a-cursor-from-a-finished-transaction) | A write through a cursor from a finished transaction is an error | 1 and a reproduction that write today, and 8 that raise today | 11 | Variant, `safe-*`, and nothing for those that raise |
| [2](#finding-2-a-sorted-key-through-a-pair) | A sorted key can't be written through a pair | 1 | 0 | Variant |
| [3](#finding-3-a-structural-slot-as-a-value) | `write` rejects structural tags | 0, and 3 that `run` refuses | 0 | Nothing |
| [12](#finding-12-parts-after-a-remove) | Parts after a remove are an error | 2 | 0 | Variant, with an error that already exists |
| [16](#finding-16-a-failed-op-that-left-something-behind) | A failed op that wrote something poisons its transaction | 3 | 12 | Variant, `safe-*` |
| [17](#finding-17-write_if_empty-and-the-snapshot) | `write_if_empty` goes by the slot as it is now, and writes where the cursor's slot is empty and the slot now is a `none` | 2 | 4 | Done: regenerated from `bd6abc3` |
| [22](#finding-22-the-concat) | A concat freezes after its join | 1 changes | 1 changes | Variant, from `bd6abc3` |
| [23](#finding-23-a-cursors-freeze) | A freeze holds for every cursor | 2 of 6 change, in the prototype | 2 of 17 change | Deferred, so nothing happens |
| [28](#finding-28-compacting-a-history-with-no-last-moment) | Compacting a history with no last moment is refused | 1 | 0 | Variant |
| [29](#finding-29-an-init-on-a-held-cursor-after-a-freeze) | Nothing: an init on a held cursor after a freeze changes a clone that shares its record, on both | 1 | 0 | Nothing, and a fixture pins it |
| [D18, D24](#d18-and-d24-refusing-a-write-from-before-a-freeze) | A write from before a freeze is refused unless it's at the transaction's body's slot and begins with an init or a write, and so is a write into committed or frozen bytes | 8, and 1 reproduction | 28, and 2 `safe-*` since D24 | Variant, `safe-*`, only for Zig. A read through such a cursor goes on working |
| [D19](#d19-opening-a-file-whose-root-header-cant-be-trusted) | A file whose root header can't be trusted raises an error, until `recover` is called | 3, and none of the 3 failing ones | 0 | Variant, with `recover` |

## A generator that keeps off all of this

`gen --port-safe` writes scripts that do none of what's listed here, so Zig's result for one is what the port has to give, on
any seed, before or after these changes go in. The scripts already committed don't change, and neither does what `gen` writes
without it. `PORT_SAFE=yes ./gen-live.sh <how many>` holds each script to that with `run --note-port-changes`, and the gate
runs 20. The notes that stay allowed are `18-init`, `18-write`, `18-reads`, `18-reads-earlier` and `1-raises`, which stay valid on the port.

| Item | What it does instead |
|---|---|
| 1 | No write through a cursor from an earlier transaction |
| 2, 3, 12, D19 | `gen` doesn't do these anyway |
| 28 | With `--compact`, a list at the root with no last moment gets one written first |
| 16 | An error from an op that wrote something goes up, and rolls the transaction back |
| 17 | `write_if_empty` only where the snapshot and the slot agree about being empty |
| 22 | No concat |
| 23 | No cursor's freeze |
| D18, D24 | After a freeze, a write only through a cursor at the transaction's body's slot, with an init, or through one made since the freeze. Nothing is kept from an op that froze during it. Reads through a cursor from before a freeze go on |

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

The port goes by the slot as it is now: it writes when that slot is empty, or when the cursor's own slot is empty and the slot
now is a `none`, and it holds back otherwise. The second half came on 2026-11-14, when the `xitdb` session found that the branch
held back after an append, whose slot in the file is a `none` marked full, which is what makes an unwritten element count, for
array lists since `89da8e7`, while the cursor's own copy is empty. Upstream writes there, and so does the port (`write-if-empty-append`).
Nothing raises an error, but what's written changes, so **no script can show this without a Zig that has the change**, which is
`fix-findings-v2` at `bd6abc3`, on `89da8e7`. There are two directions:

Where the snapshot is empty and the slot holds a value, so the original overwrites a value it can't see, and the port leaves it:

<!-- list 17-overwrites -->
- `tests/generated`: compact-203 (1), gen-16 (1), reads-101 (1), reads-107 (1)
- `tests/valid`: path-api-edges (1)
<!-- end -->

Where the snapshot has something and the slot is empty, so the original holds back, and the port writes:

<!-- list 17-holds-back -->
- `tests/from-other-zig`: write-if-empty-emptied-slot (3)
<!-- end -->

**This has been done.** `tests/zig-commits.txt` says which expected files come from `bd6abc3`. The prototype's prediction held
for every script. The fixtures have the first direction in these two scripts, and in no generated one, as `gen --port-safe` keeps
off it:

| Script | On the fixes branch | What happened |
|---|---|---|
| `compact-203`, `gen-16`, `reads-107`, `reads-101` | different bytes for the first three, and the same for the last | Only for Zig, as each has stale writes too |
| `path-api-edges` | fails at the read after the write, which expects the overwritten value | Only for Zig, as the gate and `mutants.sh` run it on the original. `path-api-edges--port` has that read and the note before it turned round |
| `write-if-empty-emptied-slot` | new | The second direction, in `tests/from-other-zig` as it fails on the original. Its `none` written behind a cursor made on an empty slot writes, by the refined rule, as on the original |
| `write-if-empty-unreachable` | new | Where it looks like the second direction and isn't, in `tests/valid` as it has the same bytes on both |

**The second direction can't be reached through the wrappers alone in one transaction.** A remove empties the map's own
slot for the key, and leaves the pair as it was. So a value cursor from `putCursor` points at something that's unreachable
and not empty, and `put(k, .{ .slot = null })` is no route, since a written none has `full` set, which isn't empty. It takes
a `kv_pair` cursor from the path API, which points at the map's slot. `src/test.zig` on that branch then puts the pair back
with the slot it captured. **A script can't do that**: `run` refuses to write a `kv_pair` slot (finding 3), and the port's
`write` rejects one. So `write-if-empty-emptied-slot` writes a none, which leaves the map working, and a uint, which shows
that it wrote, as reading that key then raises `UnexpectedTag`.

**A cursor from a rolled-back transaction** has a position past the end of the file. On the fixes branch, `write_if_empty` through
one raises the reader's error, where it used to do nothing if the snapshot had something. No script here can do that,
because `run` refuses every use of such a cursor (`tests/invalid/cursor-from-rolled-back-transaction`, section 10). So it
isn't in the lists under finding 1 or finding 24, and nothing happens to any script. The port's guard for reads through a
cursor from a transaction that didn't commit (D22) is what will report it there.

## Finding 22: the concat

The port freezes after the join, as the fix branch does. Every script with a concat:

<!-- list 22 -->
- `tests/generated`: compact-202 (1), compact-203 (1), compact-205 (4), compact-206 (3), gen-1 (2), gen-10 (2), gen-11 (3), gen-13 (4), gen-16 (1), gen-17 (4), gen-4 (2), gen-7 (2), gen-8 (2), reads-101 (1), reads-103 (4), reads-106 (1), reads-112 (1), replica-302 (2), replica-304 (1), replica-305 (2)
- `tests/undefined`: concat-stale-slot (2)
- `tests/valid`: body-write-after-freeze (1), deep-linked (1), every-construct-linked (2)
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
changes. `zig-findings.md` says a fix makes a cursor's freeze equivalent to `Database.freeze`, or needs another design. The
`frozen-clone-*` makers in `tests/undefined` made the `sorted-*` and `linked-*` inputs once, and those stay as they are, so
the fixtures that only read them don't change with a fix. Every script with a cursor's freeze:

<!-- list 23 -->
- `scripts`: 03-clone-and-freeze (1)
- `tests/generated`: compact-201 (1), compact-203 (3), compact-205 (2), gen-10 (2), gen-12 (1), gen-13 (1), gen-17 (2), gen-2 (2), gen-3 (1), gen-6 (1), gen-7 (1), reads-101 (2), reads-102 (1), reads-103 (2), reads-108 (1), replica-302 (2), replica-305 (2)
- `tests/undefined`: frozen-clone-linked-append (1), frozen-clone-linked-counts-above-leaves (1), frozen-clone-linked-counts-below-leaves (1), frozen-clone-linked-header-above-tree (1), frozen-clone-linked-header-below-tree (1), frozen-clone-linked-read (1), frozen-clone-sorted-counts-above-leaves (2), frozen-clone-sorted-counts-below-leaves (2), frozen-clone-sorted-header-above-tree (2), frozen-clone-sorted-header-below-tree (2), frozen-clone-sorted-iterator-past-tree (1), frozen-clone-sorted-read (1)
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

## Finding 29: an init on a held cursor after a freeze

**The port refuses it, since D24**, which is why this is here. After a freeze, an init through a cursor held from before it was
allowed, as the way to go on (D22 item 1), and Zig still allows it.
It copies the collection, and writes where the copy is into the cursor's slot in place. That slot is in a record made before
the freeze, and a clone made before the freeze by copying a map's slot shares the record, so the clone changes too. Zig's own
comment on `freeze` gives the same advice, to reinitialize writable collections, and the docs session found what it does to a
clone. The engine can't tell a shared record from one that isn't, so D24 allows an init after a freeze only through the
transaction's body, whose slot nothing in the transaction can copy, and the Swift layer's handles resolve themselves from the
root (D18 item 3) to give the convenience back.

`tests/valid/held-init-after-freeze` pins it, in two transactions. In the first, `a` has a list of one element, `b` is a clone of
`a`, and after a `db_freeze` an init and an append through the cursor held on `a.list` give `a.list` and `b.list` two elements
each. In the second, the same done by going down from the root again, with an init at each level, copies the record, so
`c.list` has two and `d.list` keeps one. It's only for Zig now, and `held-init-after-freeze--port` refuses the first init with
`StaleCursor` and goes on from the body instead, so `a.list` has two and `b.list` keeps one.

**It can lose a write, too.** If something has copied the record the held cursor's slot is in, the root doesn't reach what the
init writes there, which is section F's lost write in `zig-findings.md`. `tests/valid/held-init-after-root-copy` pins two ways:
a path from the root that copies the root's record before the init through the held cursor, and, with nothing from the root, an
init through one held cursor whose get copies the record another held cursor's slot is in. Each loses its write, on Zig at
`6b93af1` and at `185af01`. It's only for Zig now: `held-init-after-root-copy--port` refuses the three inits through held
cursors with `StaleCursor`, and writes what they would have through the body or a cursor made from it since the freeze, so
nothing is lost.

## Finding 28: compacting a history with no last moment

Zig compacts a list at the root with no elements, or whose last slot is truly empty, to an empty root. So the list goes, and
every moment written before that last one. Since `89da8e7` an element appended and never written is a `none` slot marked full,
a moment set to nothing, which compacts, so a truly empty last slot is only in a version 1 file written before it, which
`compact-roots` and `compact-sliced-history--port` have on inputs. The port refuses it with `EmptyLastMoment`, before writing
anything (D22 item 7). Every `compact` of such a history:

<!-- list 28 -->
- `tests/valid`: compact-roots (2)
<!-- end -->

`compact-roots--port` expects the error on both of the compactions in `compact-roots`, and on one of them again into a target
with something in it, as the source is refused before the target is looked at. Then each source gets a last moment written,
and compacts into the name it was refused, which still needs a `file_id`. A new case is the one that finding 28 was widened by: three
moments written and a fourth appended, into an empty target, which stays as it was. Its expected file is Zig's with those
compactions left out, which was compared with a copy that has a `committed_size` in their place: every one of its 42 databases
is the same bytes on each kind, apart from commit IDs.

**`gen` does it now and then.** A history it makes always has a last moment, as every moment it commits has a hash map in
it, and `undo` copies one. But a list at the root that isn't a history can be sliced to nothing, or end with an append that
wrote nothing, as the gate's seed 1000015 does. So with `--compact`, `gen --port-safe` writes a last moment first, if there
isn't one, with a top-level `write_path` of `["array_list_init", "array_list_append", {"write": {"uint": 1}}]`. That leaves
every other script as it was, and none of the committed ones has the case. Over 2000 fresh seeds with `gen-live.sh`'s flags, 2
got that write, none was noted `28`, and all of them gave Zig's bytes under `--port`. `gen-live.sh` with `PORT_SAFE=yes` would
reject a script that did it, as `28` isn't one of the notes it allows.

## D18 and D24: refusing a write from before a freeze

The port refuses a write through a cursor made before the last freeze, whether that's `db_freeze` or a concat, **an init
included, unless the cursor's slot is the transaction's body's and the write begins with an init or a write** (D24, which
narrows D18 and D22, and its item 3 as refined on 2026-11-09). A cursor counts as made when the op
that made it began, so what a concat gives back is stale too, and so is what a path gives back after a `db_freeze` in its
callback. And it refuses a write that would change committed or frozen bytes, by position, with `ImmutableBytes`, which is
finding 13's shape too. It also gets option B, which is errors in place of traps, and Swift handles that resolve themselves.
B and the handles don't touch any script.

These write through a cursor made before a freeze in the same transaction, other than with a path that begins with an init part,
or at the body's slot with one that begins with a write:

<!-- list 18-other -->
- `tests/generated`: compact-201 (1), compact-202 (4), compact-203 (2), compact-205 (1), compact-206 (1), gen-1 (1), gen-10 (3), gen-12 (5), gen-13 (2), gen-17 (4), gen-18 (1), gen-2 (3), gen-3 (3), gen-4 (1), gen-6 (1), gen-7 (4), gen-8 (1), reads-101 (2), reads-102 (3), reads-103 (2), reads-104 (1), reads-105 (2), reads-107 (2), reads-110 (5), replica-302 (2), replica-303 (2), replica-305 (3)
- `tests/valid`: every-construct-linked (11)
<!-- end -->

| Script | What happens |
|---|---|
| `every-construct-linked` | Variant, which pins the guard on each kind of write |
| `several-databases` | Its one write through `e` now comes before the `db_freeze`, with the same bytes |
| `tests/undefined/concat-stale-slot` | Nothing. It's a reproduction, and only ever run on Zig |
| the generated scripts | Only for Zig. `gen --port-safe` treats every cursor from before a freeze as gone for a write, apart from one at the transaction's body's slot, with an init, and fine for a read |

These go on with a path that begins with an init part **through a cursor at the transaction's body's slot**, which is how
`Database.freeze`'s comment says to carry on, and which the port still allows:

<!-- list 18-init -->
- `scripts`: 03-clone-and-freeze (1)
- `tests/generated`: compact-201 (45), compact-202 (8), compact-203 (9), compact-205 (69), compact-206 (7), gen-1 (4), gen-10 (11), gen-11 (3), gen-12 (2), gen-13 (54), gen-15 (2), gen-16 (3), gen-17 (15), gen-18 (2), gen-2 (96), gen-3 (82), gen-4 (4), gen-5 (4), gen-7 (10), gen-8 (47), gen-9 (2), reads-101 (47), reads-102 (9), reads-103 (9), reads-104 (8), reads-105 (4), reads-106 (3), reads-107 (5), reads-108 (3), reads-110 (9), reads-111 (2), reads-112 (5), replica-302 (10), replica-303 (48), replica-304 (2), replica-305 (93), replica-306 (42), safe-1 (6), safe-10 (3), safe-12 (2), safe-13 (4), safe-15 (3), safe-17 (5), safe-2 (7), safe-3 (4), safe-4 (6), safe-5 (5), safe-6 (4), safe-7 (2), safe-8 (3), safe-9 (3), safe-compact-201 (5), safe-compact-202 (3), safe-compact-203 (4), safe-compact-205 (3), safe-reads-101 (2), safe-reads-102 (3), safe-reads-103 (3), safe-reads-104 (2), safe-reads-105 (2), safe-reads-106 (5), safe-reads-107 (4), safe-reads-108 (6), safe-reads-110 (2), safe-reads-111 (5), safe-replica-301 (2), safe-replica-302 (2), safe-replica-303 (4), safe-replica-304 (6), safe-replica-305 (4), safe-replica-306 (2)
- `tests/undefined`: concat-stale-slot (3)
- `tests/valid`: deep-linked (1), deep-sorted (1), deep-sorted-existing (1), deep-tries (1), held-init-after-freeze (1), held-init-after-root-copy (1)
<!-- end -->

These go on at the body's slot by **writing first** (D24 item 3): a path whose first part is a write, `write`, which is a
one-part write path, or `write_if_empty`, which calls it. What follows the first part goes through what it wrote, as after an
init. It's safe for the same reason, and the original allows it:

<!-- list 18-write -->
- `tests/generated`: gen-14 (8), gen-18 (7), reads-109 (4)
- `tests/valid`: body-write-after-freeze (10)
<!-- end -->

Three generated scripts do it through `run_context`'s cursor, which is a transaction's body too. **`gen-14` is a fixture now**:
its 8 writes after a freeze were all of this kind, and it does nothing else the port refuses. Its bytes are Zig's, at
`185af01` too. `gen-18` has 7 of them and one write through a cursor from before a freeze that stays refused, and `reads-109`
has 4 and a write through a cursor from an earlier transaction (finding 1), so those two stay only for Zig. That was found by
running every script under `--port` with the runner before the refinement and after it: nothing else changed. `body-write-after-freeze--port` is the hand-written script with what stays refused through the body put in: a
`writer`, an empty path, and a path whose first part is neither an init nor a write.

And these do an init through a cursor at any other slot, which **the port refuses since D24**:

<!-- list 18-init-held -->
- `tests/generated`: compact-201 (1), compact-202 (1), compact-203 (2), compact-205 (2), gen-10 (1), gen-13 (1), gen-17 (1), gen-7 (1), reads-101 (2), reads-102 (1), reads-105 (2), reads-108 (1), replica-302 (3), replica-305 (2)
- `tests/valid`: held-init-after-freeze (1), held-init-after-root-copy (3)
<!-- end -->

**Why the init through a held cursor went** (D24). An init writes to the cursor's slot, which is from before the freeze, in place.
If something has copied the record that slot is in, a clone made before the freeze or a second way down from the root since, the
root no longer reaches what the init wrote, and the write is lost (findings 29 and 30, `held-init-after-root-copy`). The body's
slot is in the transaction's own record, which nothing in the transaction can copy, so an init at that slot can't be lost,
through whichever cursor. The package's engine goes by that position, so the format does too. What follows the init in the path
goes through what it made. Rule C, which kept the exception until a root path had copied something,
was modelled and found unsound in two of three cases.

**What it cost**, measured on the fixtures before the change, with the package's engine showing the same 9 fixtures failing:
of 198 inits after a freeze, 193 are at the body's slot and keep working. The fixtures that change are these 9, with 16 writes:

| Fixture | What happened |
|---|---|
| `held-init-after-freeze`, `held-init-after-root-copy` | Only for Zig, with variants that refuse each init at another slot (1 and 3) and show nothing lost |
| `every-construct-linked--port` | 2 writes: through what the concat gave back, which is finding 22's pin, and the init through `la`. Both go on through the body now, and its expected file is from `185af01` again |
| `stale-cursors--port` | 2 writes: the init through a cursor from before the `db_freeze`, with the way on through the body, and an empty path through what the concat gave back |
| `safe-reads-101`, `safe-reads-108` | 3 writes, lost on Zig: in each, a path begins with an init, a `db_freeze` in its callback runs, and what it gives back was kept. Its slot is in the record the init copied before the freeze, and the next op copies that record again. With a cursor counting as made when its op began (D24 item 6a), that's stale, and `safe-reads-101` also had an init through a nested callback's cursor. `gen --port-safe` keeps nothing from an op that froze during it, and stops writing through a nested callback's cursor after a freeze. Their bytes change |
| `overwriting-committed-bytes--port`, `-linked`, `-sorted` | 5 writes of finding 13's shape, with no freeze at all: a path that skips an init part and writes into committed bytes, refused by position with `ImmutableBytes`. The last two are only for Zig now, with variants. Each variant has the refusal both ways: through a fresh cursor at the committed list or tree nothing is written before it, and through the moment's map the get copies the entry's record first, which poisons the transaction. A get that adds a key to a committed map writes the entry first, so it poisons too |

Rule B as modelled first went by the handle, the callback's own cursor, and counted 31 writes in 23 fixtures. Most of those went
through the body's name after a generated script had bound to it what an init through the body gave back. That's a cursor at the
body's slot, which the engine allows, and so does the format now. `gen --port-safe` changed five `safe-*` scripts, three of them
with the same bytes.

**A read through such a cursor stays allowed too**, as a snapshot read (D22, as narrowed). These do that in the same
transaction, so they're what hold the port to it:

<!-- list 18-reads -->
- `tests/generated`: compact-201 (1), compact-203 (2), compact-205 (1), gen-10 (4), gen-12 (1), gen-13 (2), gen-14 (2), gen-17 (7), gen-18 (2), gen-2 (2), gen-3 (5), gen-8 (2), reads-101 (4), reads-103 (3), reads-104 (6), reads-105 (2), reads-108 (1), reads-109 (2), reads-110 (4), replica-302 (2), replica-303 (1), replica-305 (3), replica-306 (1), safe-14 (1), safe-3 (1), safe-compact-201 (1), safe-reads-103 (3), safe-reads-104 (3), safe-reads-106 (4), safe-reads-110 (2), safe-replica-306 (1)
- `tests/undefined`: concat-stale-slot (1)
- `tests/valid`: body-write-after-freeze (4), every-construct-linked (2)
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
- `tests/valid`: recovery-open-errors (5), recovery-open-errors-version-1 (5), replicate-bad-trailer (1)
<!-- end -->

| Script, and what its `reopen` meets | Zig | The port |
|---|---|---|
| `recovery-open-errors`: a bad magic number | `InvalidDatabase` | The same error, as this isn't a database |
| `recovery-open-errors`: a committed size smaller than a new database, past the end of the file, or that doesn't end at a trailer | `InvalidDatabase`, `TruncatedDatabase`, `InvalidDatabase` | `UntrustedRootHeader` |
| `recovery-open-errors`: a changed root slot in the last trailer | `InvalidDatabase` | `UntrustedRootHeader`, and `recover` loses that commit |
| `replicate-bad-trailer`: a last trailer with its commit ID and checksum overwritten | `InvalidDatabase` | `UntrustedRootHeader`, as its magic number is good, and `recover` goes back to 57 |
| `recovery-open-errors-version-1`: the same on a version 1 file, with its committed size at 29 | the same | the same, and `recover` writes the size at 29 and leaves the copy of the root slot |
| `op-after-failed-reopen`, `reopen-error-not-handled`, `reopen-wrong-error` | `InvalidDatabase`, as all three have a bad magic number | The same error, so they still fail |

**The variants of those three** expect the error, then `recover`, then the reads. A `reopen` writes nothing, so that's the same
as in Zig. `recover` isn't in Zig, so `run --port` does it itself, on the file's bytes. What it leaves is exactly a file cut off
at that trailer, with a root header that says so, and that's what the port's has to leave.

`recovery-torn-root-slot` and `recovery-garbage-padding` aren't affected, as what's before the committed size is never read.
`replicate-failed-first-sync` was here until `89da8e7`: a failed sync at 0 leaves a database without a first commit now, which
the original opens, and the port does what the original does there (D31 item 4), so it's a plain fixture and its variant is
gone. `recover` on such a database scans as on any other (`recover-without-first-commit--port`).

## Upstream's 89da8e7: what it closes, narrows or leaves

Upstream moved six commits past `6b93af1` on 2026-11-10 (D31). Each of the port's differences was run again on `89da8e7`
(`second-zig.sh` and the step report of conformance-09) and sorted by what upstream's change does to it. **Closes** means
the original now does what the port does, so the difference goes and its variant folds back into a plain fixture.
**Narrows** means part of it closes and the rest stays, on a smaller set of files or cases. **Leaves** means upstream didn't
touch it.

| Entry | Finding | Upstream's change | What happens |
|---|---|---|---|
| `tests/port-differs/none-into-buffer` | 8 | none | Leaves |
| `tests/port-differs/stream-none` | 21 | none | Leaves |
| `tests/port-differs/stream-short-no-position` | 9 | `71ee0cf`: a key-only entry's key from `read_key_value_pair` has the entry's position | Narrows: the key from `{"sorted_map_get": {"key": ...}}` still has no position and still raises `ExpectedSlotPosition`, and the half through `read_key_value_pair` streams in both, which `stream-short-set-key` pins as a plain fixture |
| `tests/port-differs/stream-short-overwritten` | 9 | none: a slot overwritten since the cursor was made is still read from the file | Leaves |
| `tests/port-differs/iterator-past-slice` | 26 | `89da8e7`: an append writes a `none` slot marked full, which counts and which the iterator gives | Narrows to a version 1 file with a truly empty slot inside a list's size, where the original at `89da8e7` still skips it and gives what's past the end (1, then 2, and after an append 1, 9 and 3), and the port gives 1, and 1 and 9. It's remade on `inputs/v1-sliced-holes`. On a file the original writes now, the two agree (`unwritten-elements`), and so they do on a version 1 file with nothing past the end (`version-1-lists`) |
| `replicate-failed-first-sync`, and its variant `--port` | D19 | `52c7283` and `92a926e`: a copy from 0 that fails leaves a database without a first commit, which opens, and `replica_state` gives zero and zero for it | Closes: the port does what the original does there (D31 item 4). The variant is gone and the script is a plain fixture |
| `recovery-open-errors`, `--port` | D19 | `bdaa55e`: version 2 opens | Leaves, as what can't be trusted is the same. `InvalidVersion` is tested at 0 and 3, and `recovery-open-errors-version-1` with its variant is the same on a version 1 file, whose committed size is at 29 |
| `replicate-bad-trailer`, `--port` | D19 | none: a trailer whose checksum fails after a sync that succeeded isn't a database without a first commit | Leaves |
| `compact-roots`, `--port` | 28 | `89da8e7`: a last moment appended and never written is a `none` slot marked full, a moment set to nothing | Narrows to a history with no moments and a last slot that's truly empty, which only a version 1 file has (`inputs/v1-unwritten-last`, a new case in both). A history whose last element was appended and never written now compacts in both |
| `compact-sliced-history--port` | 28 | the same | Narrows: the list sliced to nothing stays refused, and its element appended in a callback that wrote nothing now compacts in both |
| `04-rollback`, `--port` | 16 | none | Leaves |
| `overwriting-committed-bytes`, `-linked`, `-sorted`, `--port` | 1, 13, D24 | none | Leave |
| `path-api-edges`, `-sorted`, `--port` | 12, 16, 17 | none | Leave. `path-api-edges--port`'s expected file is from the fixes branch at `bd6abc3` |
| `every-construct-linked`, `--port` | 22, D24 | none | Leaves. Its expected file is from `bd6abc3` |
| `every-construct-sorted`, `--port` | 2 | none | Leaves |
| `held-init-after-freeze`, `held-init-after-root-copy`, `--port` | 29, 30, D24 | none | Leave |
| `body-write-after-freeze--port` | D24 | none | Leaves |
| `write-kv-pair-slot--port`, `write-sorted-kv-pair-slot--port` | 3 | none | Leave |
| `rolled-back-reads--port`, `stale-cursors--port` | D16, D18 | none | Leave |
| `write-if-empty-emptied-slot` | 17 | `89da8e7`: an append leaves a `none` marked full where the cursor's slot is empty | Leaves, with the rule refined (below): it writes now where a `none` was written behind a cursor made on an empty slot, as upstream does. From `bd6abc3` |
| the 33 generated scripts in `tests/zig-only.txt` | 1, 16, D24 | none | Leave |
| `recover` | D19 | `92a926e`: a database without a first commit is one the original opens | Leaves, as an explicit call that scans as it always did, on that state too (the director's ruling): `recover-without-first-commit--port` |

**Finding 17's rule is refined** for the fixes branch and the port, on the `xitdb` session's finding that the branch's
`writeIfEmpty` held back after an append or an insert, whose slot in the file is a `none` marked full while the cursor's own
copy is empty: it writes when the slot as it is now is empty, or when the cursor's own copy is empty and the slot now is a
`none`, and it holds back whenever the slot holds a value, and whenever the cursor's copy holds something and the slot isn't
empty. `write-if-empty-append` is the append case on both lists, the same on `89da8e7` and on the branch.

## What this doesn't cover

- **Finding 24** goes when finding 1's guard comes in, except by the internal path API. `tests/dump/dangling` is the only
  script that does this, and `gen` keeps away from it.
- **The fixes the port already has**, which are 8, 9, 21 and 26, are in `tests/port-differs/`, and no valid script relies on
  them. Findings 10, 11 and 15 are the same: `run` and `check.sh` keep them out of the scripts.
- **The notes go by what a script does, not what it means.** A script is listed if it does the thing, even if it makes no
  difference to its bytes, like `reads-101`. And "a cursor made before a freeze" is by name: two names for one slot count
  separately.
- **`run --port` isn't the port.** It says what the guards should do, and the port's own runner is what shows that they do.
