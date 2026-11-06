# xitdb conformance harness

An oracle for the Swift port of xitdb: it records what the Zig implementation does, so the port can be checked
for byte identity. It is built from the Zig source and the file format notes only, and is deliberately
independent of the Swift code.

- `SCRIPT-FORMAT.md`: the script format and the sidecar, enough to write a runner from.
- `src/run.zig`: `run <script> <out.db>`, the Zig runner.
- `src/detcheck.zig`: `detcheck <a.db> <b.db>`, which checks that two runs of a script differ only in their commit
  IDs and checksums.
- `scripts/`: hand-written scripts for the hard parts of the format.
- `tests/valid/`: scripts that run the rest of the format, including its corners.
- `tests/invalid/`: scripts that must fail, each for the reason in its description.
- `check.sh`: the gate. It builds everything and checks all of the above, in debug and release builds and across
  all three storage kinds.

It uses the Zig original by path, as `../../xitdb`, without modifying it. It needs Zig 0.17.1.

```
./check.sh
zig-out/bin/run scripts/01-list-root-hash-map.json out/01.db
```
