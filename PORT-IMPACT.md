# What the port's agreed differences touch

After its parity gate, the Swift port adopts guards and fixes that the Zig original doesn't have
(`director/zig-findings.md`, D17, D18 and D19). This says which scripts rely on what each one changes, and what would
happen to each script. Only finding 17 has been done, from the Zig at `185af01`, and its section says what came of it.
Otherwise no script has changed, no `.port` variant has been written, and every fixture still comes from the Zig original
at `6b93af1`.

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
| **`.port` variant** | A copy of the script where the op gets `expect_error` with the port's error, and whatever came after it is adjusted. Written after parity, once the error's name exists |
| **Regenerated** | Its expected file comes from a fixed Zig, with `second-zig.sh --regenerate` |
| **New from `gen`** | A generated script stops doing this because `gen` gets a rule, so the seed gives another script |
| **Nothing** | |

**A `.port` variant can still have an oracle.** Zig doesn't have these guards, so it can't run the variant. But a guard
that refuses before it writes anything leaves the file as if the op had never been there. So Zig can run the same script
with the op taken out, and that file is what the port's variant has to match. That depends on the guard writing nothing,
which is worth holding the port to. It doesn't work for finding 17, which changes what's written and raises nothing.

## Summary

| Item | What the port changes | Hand-written scripts | Generated | Mostly |
|---|---|---|---|---|
| [1](#finding-1-a-write-through-a-cursor-from-a-finished-transaction) | A write through a cursor from a finished transaction is an error | 1 and a reproduction that write today, and 8 that raise today | 11 | `.port` variant, new from `gen`, and nothing for those that raise |
| [2](#finding-2-a-sorted-key-through-a-pair) | A sorted key can't be written through a pair | 1 | 0 | Regenerated, tried on the fix branch |
| [3](#finding-3-a-structural-slot-as-a-value) | `write` rejects structural tags | 0, and 3 that `run` refuses | 0 | Nothing |
| [12](#finding-12-parts-after-a-remove) | Parts after a remove are an error | 2 | 0 | `.port` variant, with an error that already exists |
| [16](#finding-16-a-failed-op-that-left-something-behind) | A failed op that wrote something poisons its transaction | 3 | 12 | `.port` variant, new from `gen` |
| [17](#finding-17-write_if_empty-and-the-snapshot) | `write_if_empty` goes by the slot as it is now | 2 | 4 | Done: regenerated from `185af01` |
| [22](#finding-22-the-concat) | A concat freezes after its join | 1 changes | 1 changes | Regenerated from `d6f3fee` |
| [23](#finding-23-a-cursors-freeze) | A freeze holds for every cursor | 2 of 6 change, in the prototype | 2 of 17 change | Waits for a design |
| [D18](#d18-refusing-a-write-from-before-a-freeze) | A write from before a freeze is refused | 2, and 1 reproduction | 31 | `.port` variant, new from `gen`. An init and a read through such a cursor go on working |
| [D19](#d19-opening-a-file-whose-root-header-cant-be-trusted) | A file whose root header can't be trusted opens at its last good trailer | 3, and none of the 3 failing ones | 0 | `.port` variant, reads only |

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
| `overwriting-committed-bytes` | `.port` variant. It exists to pin this, so its two writes get the new error, and the reads after them that expect the overwritten values change by hand. The part that skips an init part stays, as finding 13 is unchanged |
| `overwriting-committed-bytes-linked`, `-sorted` | Nothing. These only skip an init part, which is finding 13. `zig-findings.md` cites `overwriting-committed-bytes*` under finding 1, and it's only the first |
| `tests/dump/dangling` | Nothing. It's there to show `dump` a dangling slot, which is finding 24, and it's only ever run on Zig |
| the generated scripts | New from `gen`, whose `someKept` chooses a kept cursor now and then. The seed then gives another script, and it's valid on both |

**It raises `ExpectedTxStart`**, when no transaction is going:

<!-- list 1-raises -->
- `scripts`: 02-nested-collections (2), 05-non-list-root (1)
- `tests/failing`: unhandled-error (1), wrong-error-name (1)
- `tests/valid`: every-construct (1), path-api-edges (1), replicate-roots (1), several-databases (2)
<!-- end -->

These are errors already. If the port keeps the name `ExpectedTxStart` for this case, **nothing happens to any of them**, and
that's the recommendation. A new name would mean a `.port` variant of each, for no gain. The new error is only needed for
the first case.

## Finding 2: a sorted key through a pair

<!-- list 2 -->
- `tests/valid`: every-construct-sorted (1)
<!-- end -->

**Regenerated.** This has been tried: on `d6f3fee`, with `expect_error: CursorNotWriteable` on that one op and nothing else
changed, `every-construct-sorted` passes. Since the error's name exists, and the fix does too, the script's new version
goes in `tests/from-other-zig/`, with its expected file from that commit. No other script does this: it's also the only
one that fails on that branch for this reason.

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

**`.port` variant**, with `PathPartMustBeAtEnd`, which already exists. The prototype fails exactly these two scripts, and
nothing else differs.

The error alone isn't enough, as the prototype showed by running them with it. It raises before removing anything, so the
next read in each fails: `path-api-edges` still has `k`, and `path-api-edges-sorted` has a count of 2 and not 1. So those
reads change by hand too, and the variants' expected files are Zig's on the script with these two ops taken out.

The port has to raise before it removes, or the oracle above doesn't hold. That's what the prototype does, and it's worth
saying in the port's guard.

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
| `04-rollback`, `path-api-edges`, `path-api-edges-sorted` | `.port` variant. The top-level op gets the new error, and what the rest of the script expects to find changes by hand, as none of that transaction is there. `04-rollback` exists to pin this, and section 7 of `SCRIPT-FORMAT.md` quotes it |
| the generated scripts | New from `gen`, which can tell in the same way whether a failed op left anything, and then let the error go up rather than handling it |

The oracle for a variant is Zig on the same script with that transaction made to fail: a `fail` at the end of its callback,
and `expect_error: ScriptAbort` on the top-level op. That rolls it back, and takes no commit ID. This one is reasoned.

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

**This has been done.** `tests/zig-commits.txt` says which expected files come from `185af01`. The prototype's prediction
held for every script:

| Script | On `185af01` | What happened |
|---|---|---|
| `compact-203`, `gen-16`, `reads-107` | different bytes | Regenerated. The scripts are the same |
| `reads-101` | the same bytes, so what it wrote in Zig doesn't last | Nothing |
| `path-api-edges` | fails at the read after the write, which expects the overwritten value | It stays, with its expected file from `6b93af1`, as the gate and `mutants.sh` run it there. `tests/from-other-zig/path-api-edges--185af01` is the same script with that read and the note before it turned round, and its expected file is from `185af01`. **No engine passes both**, so the port drops the first when it takes this change |
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

Only two have different bytes on `d6f3fee`, and these are **regenerated**, once the parity gate has passed:

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

There's no fix yet, because the design is open: `zig-findings.md` says it makes a cursor's freeze equivalent to
`Database.freeze`, or it needs another design. So nothing can be regenerated until there is one. Every script with a
cursor's freeze:

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

These write through a cursor made before a freeze in the same transaction, other than with a lone init part:

<!-- list 18-other -->
- `tests/generated`: compact-201 (44), compact-202 (7), compact-203 (7), compact-205 (63), compact-206 (1), gen-1 (1), gen-10 (11), gen-12 (7), gen-13 (53), gen-14 (8), gen-17 (11), gen-18 (10), gen-2 (97), gen-3 (80), gen-4 (1), gen-6 (1), gen-7 (10), gen-8 (44), reads-101 (48), reads-102 (8), reads-103 (5), reads-104 (9), reads-105 (7), reads-107 (2), reads-108 (3), reads-109 (4), reads-110 (14), replica-302 (9), replica-303 (48), replica-305 (93), replica-306 (38)
- `tests/undefined`: concat-stale-slot (3)
- `tests/valid`: every-construct-linked (11), several-databases (1)
<!-- end -->

| Script | What happens |
|---|---|
| `every-construct-linked` | `.port` variant, or its concat's cursor gets reinitialized before writing, which makes it valid on both. It has 11 of these |
| `several-databases` | Nothing to do with what it pins: its one write through `e` after a `db_freeze` can have an init before it, and be valid on both. The script can change at any time, and it would change the fixture's bytes |
| `tests/undefined/concat-stale-slot` | Nothing. It's a reproduction, and only ever run on Zig |
| the generated scripts | New from `gen`, which needs a rule that treats every cursor from before a freeze as gone. It has this for a concat already, as `first_safe_kept` |

And these write through such a cursor with a lone init part, which is how `Database.freeze`'s comment says to carry on:

<!-- list 18-init -->
- `scripts`: 03-clone-and-freeze (1)
- `tests/generated`: compact-201 (3), compact-202 (6), compact-203 (6), compact-205 (9), compact-206 (7), gen-1 (4), gen-10 (4), gen-11 (3), gen-13 (4), gen-15 (2), gen-16 (3), gen-17 (9), gen-2 (2), gen-3 (5), gen-4 (4), gen-5 (4), gen-7 (5), gen-8 (4), gen-9 (2), reads-101 (3), reads-102 (5), reads-103 (6), reads-105 (1), reads-106 (3), reads-107 (5), reads-108 (1), reads-111 (2), reads-112 (5), replica-302 (6), replica-303 (2), replica-304 (2), replica-305 (5), replica-306 (4)
- `tests/valid`: deep-linked (1), deep-sorted (1), deep-sorted-existing (1), deep-tries (1)
<!-- end -->

**These go on working** (D22). That init writes to the cursor's slot, which is from before the freeze, so a guard that went
by the position of what's being written would refuse it. Inside a callback, there's no other way on: the callback's cursor
is the only way to the moment, and a write on a root cursor raises `NestedTopLevelWrite`. So the guard goes by when the
cursor was made, and lets an init through.

**A read through such a cursor stays allowed too**, as a snapshot read (D22, as narrowed). These do that in the same
transaction, so they're what hold the port to it:

<!-- list 18-reads -->
- `tests/generated`: compact-201 (1), compact-203 (2), compact-205 (1), gen-10 (4), gen-12 (1), gen-13 (2), gen-14 (2), gen-17 (7), gen-18 (2), gen-2 (2), gen-3 (5), gen-8 (2), reads-101 (4), reads-103 (3), reads-104 (6), reads-105 (2), reads-108 (1), reads-109 (2), reads-110 (4), replica-302 (2), replica-303 (1), replica-305 (3), replica-306 (1)
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

The port finds the last trailer whose checksum verifies, and opens there. Every `reopen` that raises `InvalidDatabase` or
`TruncatedDatabase`:

<!-- list 19 -->
- `tests/failing`: op-after-failed-reopen (1), reopen-error-not-handled (1), reopen-wrong-error (1)
- `tests/valid`: recovery-open-errors (5), replicate-bad-trailer (1), replicate-failed-first-sync (1)
<!-- end -->

Which of them would change depends on what counts as not being able to trust the header, which is for the port to decide.
Going by section G of `zig-findings.md`, as reasoned:

| Script, and what its `reopen` meets | Zig | The port, probably |
|---|---|---|
| `recovery-open-errors`: a bad magic number | `InvalidDatabase` | The same error, as this isn't a database |
| `recovery-open-errors`: a committed size smaller than a new database | `InvalidDatabase` | Opens at the last good trailer |
| `recovery-open-errors`: a committed size past the end of the file | `TruncatedDatabase` | Opens at the last good trailer |
| `recovery-open-errors`: a committed size that doesn't end at a trailer | `InvalidDatabase` | Opens at the last good trailer |
| `recovery-open-errors`: a changed root slot in the last trailer | `InvalidDatabase` | Opens at the commit before it, and **a commit is lost without a word** unless the port says so. This is the one to think about |
| `replicate-bad-trailer`: a last trailer with its commit ID and checksum overwritten | `InvalidDatabase` | Opens at the commit before it, as in the row above |
| `replicate-failed-first-sync`: a file a byte short of what its root header says, after a failed sync | `TruncatedDatabase` | Opens at the last good trailer, which here is the first commit, at 62 |
| `op-after-failed-reopen`, `reopen-error-not-handled`, `reopen-wrong-error` | `InvalidDatabase`, as all three have a bad magic number | The same error, so they still fail |

**`.port` variant** of `recovery-open-errors`, `replicate-bad-trailer` and `replicate-failed-first-sync`. They'd have what the
file holds after opening in place of the error. A `reopen` writes nothing in Zig, so if the port's doesn't either, the
expected files stay the same, and only the script's expectations differ. If it repairs the root header as it opens, the
expected files would need that too, with no Zig to say what's right.

`recovery-torn-root-slot` isn't affected, as the root slot in the header is never read.

## After parity, what `gen` needs

The generated scripts are in most of these lists because `gen` tries things, not because anything needs them. With one
`gen` profile that keeps away from all of these, the generated scripts would be valid on Zig and on the port at once, and
go on being compared byte for byte:

| It would have to stop | Which it does in |
|---|---|
| using a cursor from a finished transaction | `someKept`, and what uses it |
| handling an error from an op that left something behind | `noteError` |
| using `write_if_empty` on a cursor whose snapshot may be stale | `writeThroughKept` |
| using a cursor from before a freeze, other than with an init | `first_safe_kept`, which only a concat sets now |

The fixed seeds would then give other scripts, whose expected files come from the same Zig, and need no fix at all. That's a
reason to do this before regenerating anything else, rather than after. It hasn't been done or tried.

## What this doesn't cover

- **Finding 24** goes when finding 1's guard comes in, except by the internal path API. `tests/dump/dangling` is the only
  script that does this, and `gen` keeps away from it.
- **The fixes the port already has**, which are 8, 9, 21 and 26, are in `tests/port-differs/`, and no valid script relies on
  them. Findings 10, 11 and 15 are the same: `run` and `check.sh` keep them out of the scripts.
- **The notes go by what a script does, not what it means.** A script is listed if it does the thing, even if it makes no
  difference to its bytes, like `reads-101`. And "a cursor made before a freeze" is by name: two names for one slot count
  separately.
- **Findings 1 and 16 and D18 haven't been tried as prototypes**, as they'd take more than a few lines of Zig. So their lists
  come only from the notes, and what happens to each script is reasoned.
