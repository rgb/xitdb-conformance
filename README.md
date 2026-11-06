# xitdb conformance harness

An oracle for the Swift port of xitdb: it records what the Zig implementation does, so the port can be checked
for byte identity. It is built from the Zig source and the file format notes only, and is deliberately
independent of the Swift code.

- `SCRIPT-FORMAT.md`: the script format and the sidecar, enough to write a runner from.
- `src/run.zig`: `run <script> <out.db>`, the Zig runner.
- `src/detcheck.zig`: `detcheck <a.db> <b.db>`, which checks that two runs of a script differ only in their commit
  IDs and checksums.
- `scripts/`: hand-written scripts for the hard parts of the format.
- `tests/valid/`: scripts that run the rest of the format, including its corners. `src/longscripts.zig` writes the ones
  that are too long to write by hand, which are named in it.
- `tests/failing/`: well-formed scripts that must fail in every runner, each for the reason in its description.
- `tests/invalid/`: scripts that `run` must reject, before running them or, for an undefined use, when it gets there.
  A second runner never sees these.
- `tests/port-differs/`: the reads that the port corrects from the start, with what Zig does and what the port does, so
  that a valid script can't use them, and the gate notices if Zig changes.
- `tests/undefined/`: what happens with the uses `SCRIPT-FORMAT.md` calls undefined, as scripts and through the
  collection wrappers. Some of it crashes the engine, so none of it is among the fixtures.
- `src/gen.zig`: `gen <seed> <out.script>`, which writes a valid random script, with reads through it if given `--reads`,
  and ending with a compaction if given `--compact`. `tests/generated/` has the ones that are committed, which
  `gen-fixed.sh` writes, and `gen-live.sh <how many>` runs as many fresh seeds as you like.
- `fixtures/`: every script with what Zig produces for it, which the Swift package copies into its test resources.
  `fixtures.sh` regenerates it, and `src/manifest.zig` lists what each script needs.
- `src/coverage.zig`: `coverage <script>...`, which checks that the scripts use everything in the format.
- `src/dump.zig`: `dump <file>`, which prints what's in a database in a form that doesn't depend on file layout.
- `src/bench.zig`: `bench`, the Zig side of the workloads in `../director/spec/benchmarks.md`. For real numbers, build
  it with `zig build -Doptimize=ReleaseFast --prefix out/release` and run `out/release/bin/bench`.
- `mutants.sh`: makes copies of the Zig original that get copying or rewriting in place wrong, and compaction and
  replication wrong, one place at a time, and shows which scripts notice. It isn't part of the gate, as it's slow.
- `second-zig.sh <checkout>`: runs all of this against another commit of the Zig implementation, and says what differs.
- `check.sh`: the gate. It builds everything and checks all of the above, in debug and release builds and across
  all three storage kinds.

It uses the Zig original by path, as `../../xitdb`, without modifying it. It needs Zig 0.17.1.

```
./check.sh
zig-out/bin/run scripts/01-list-root-hash-map.json out/01.db
```

## Another Zig

The fixtures come from the Zig original at `../../xitdb`. When a change to Zig is being tried, or the fixtures are
to follow one:

```
./second-zig.sh ../../xitdb-fixes
```

That exports the commit into a folder under `out/` together with what's committed here, builds the harness against it,
and changes nothing in either repository. It says, for that commit:

- which fixtures have the same bytes, which have different ones, and which scripts fail, with why;
- whether the scripts that should fail still do;
- for each behaviour in `tests/port-differs`, whether it does as the original does or as the port does;
- what's changed from `tests/undefined/expected.txt`;
- how many generated scripts `gen` would write differently.

Differences are what it's there to find, so they don't make it fail.

**Fixtures from two commits can sit side by side.** The manifest has a `zig_commit` for each fixture, and it's the commit
at `../../xitdb` unless `tests/zig-commits.txt` says otherwise. To follow a change, one fixture at a time:

1. `./second-zig.sh --regenerate <name>[,<name>...] <checkout>` takes the expected files from that commit and records it.
2. Commit `tests/zig-commits.txt`, then run `./fixtures.sh` for the manifest, and commit that.

`check.sh` and `fixtures.sh --check` can't run those fixtures on the Zig at `../../xitdb`, so they only check that the
files are there, and say how many that is. `second-zig.sh` against the commit in question is what checks them.

**A script that needs changing.** One that fails on the new commit because it pins the old behaviour stays, for as long as
the port needs it. The new version goes in `tests/from-other-zig/` under a name of its own, like `<name>--<commit>`, since
the gate doesn't run that folder on the Zig at `../../xitdb`.

**The generated scripts** are scripts once they're committed, even though `gen` depends on the engine it's built against:
it looks at what's there to decide what to do next, and writes what comes back as an expectation. So after a change to
Zig, `gen` can write something else for the same seed, and that isn't a reason to change the committed one. So:

1. A generated script that still passes on the new commit stays as it is. If its bytes differ, it's regenerated like any
   other fixture, with step 1 above.
2. One that fails on it pins the old behaviour, and it's treated like the script above: from the same seed, with the `gen`
   in `second-zig.sh`'s folder, and into `tests/from-other-zig/` as `gen-<seed>--<commit>`.
3. `gen-fixed.sh --check` goes on holding `gen` to the Zig at `../../xitdb`. What `second-zig.sh` says about `gen` is
   for information.
4. To look for new trouble on the new commit, `BIN=<that folder>/repo/conformance/zig-out/bin ./gen-live.sh <how many>`
   runs fresh seeds on it. The rules in `gen` that keep it from undefined uses stay until the port has what fixes them, as
   keeping away from something that's now safe does no harm.

Nothing has been regenerated from a fixed Zig yet.
