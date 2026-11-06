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
- `src/gen.zig`: `gen <seed> <out.script>`, which writes a valid random script. `tests/generated/` has the ones that
  are committed, which `gen-fixed.sh` writes, and `gen-live.sh <how many>` runs as many fresh seeds as you like.
- `fixtures/`: every script with what Zig produces for it, which the Swift package copies into its test resources.
  `fixtures.sh` regenerates it, and `src/manifest.zig` lists what each script needs.
- `src/coverage.zig`: `coverage <script>...`, which checks that the scripts use everything in the format.
- `src/dump.zig`: `dump <file>`, which prints what's in a database in a form that doesn't depend on file layout.
- `src/bench.zig`: `bench`, the Zig side of the workloads in `../director/spec/benchmarks.md`. For real numbers, build
  it with `zig build -Doptimize=ReleaseFast --prefix out/release` and run `out/release/bin/bench`.
- `mutants.sh`: makes copies of the Zig original that get copying or rewriting in place wrong, and compaction and
  replication wrong, one place at a time, and shows which scripts notice. It isn't part of the gate, as it's slow.
- `check.sh`: the gate. It builds everything and checks all of the above, in debug and release builds and across
  all three storage kinds.

It uses the Zig original by path, as `../../xitdb`, without modifying it. It needs Zig 0.17.1.

```
./check.sh
zig-out/bin/run scripts/01-list-root-hash-map.json out/01.db
```
