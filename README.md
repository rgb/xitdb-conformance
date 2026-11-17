# xitdb conformance harness

An oracle for the Swift port of xitdb: it records what the Zig implementation does, so the port can be checked
for byte identity. It is built from the Zig source and the file format notes only, and is deliberately
independent of the Swift code.

- `SCRIPT-FORMAT.md`: the script format and the sidecar, enough to write a runner from.
- `src/run.zig`: `run <script> <out.db>`, the Zig runner. With `--port` it acts out the guards the port has, on the Zig engine.
- `src/detcheck.zig`: `detcheck <a.db> <b.db>`, which checks that two runs of a script differ only in their commit
  IDs and checksums.
- `scripts/`: hand-written scripts for the hard parts of the format.
- `tests/valid/`: scripts that run the rest of the format, including its corners. `src/longscripts.zig` writes the ones
  that are too long to write by hand, which are named in it.
- `tests/failing/`: well-formed scripts that must fail in every runner, each for the reason in its description.
- `tests/from-other-zig/`: scripts that only pass on a later Zig commit, which `tests/zig-commits.txt` names. The gate
  doesn't run them, and `second-zig.sh` against that commit does.
- `tests/port-variants/`: the port's versions of scripts that pin what it refuses, as `<name>--port`, which `run --port` runs.
  `tests/zig-only.txt` lists what they replace. Those go on running on Zig, and aren't fixtures. Some have no Zig script, or
  one in `tests/invalid/`, as what they do is an undefined use in Zig, and their oracle is Zig without what the port refuses.
- `tests/inputs/`: files that scripts start from with `raw_load`: version 1 databases the original wrote at `6b93af1`, as
  nothing creates version 1 any more, and clones the freeze hazard left with a header that disagrees with its tree, which
  only an undefined use makes. `fixtures.sh` copies them to `fixtures/inputs/`, and their `README.md` says where each came
  from.
- `tests/invalid/`: scripts that `run` must reject, before running them or, for an undefined use, when it gets there.
  A second runner never sees these.
- `tests/port-differs/`: the reads that the port corrects from the start, with what Zig does and what the port does, so
  that a valid script can't use them, and the gate notices if Zig changes.
- `tests/undefined/`: what happens with the uses `SCRIPT-FORMAT.md` calls undefined, as scripts and through the
  collection wrappers. Some of it crashes the engine, so none of it is among the fixtures. The `frozen-clone-*` makers
  there made the `sorted-*` and `linked-*` inputs, which the scripts of the same names in `tests/valid/` read, and the
  `linked-*-writes` scripts write to.
- `src/gen.zig`: `gen <seed> <out.script>`, which writes a valid random script, with reads through it if given `--reads`,
  ending with a compaction if given `--compact`, with a sync to a replica if given `--replicate`, and keeping off what the
  port changes if given `--port-safe`. `tests/generated/` has the ones that are committed, which `gen-fixed.sh` writes, and
  `gen-live.sh <how many>` runs as many fresh seeds as you like, or `PORT_SAFE=yes ./gen-live.sh <how many>` with `--port-safe`.
- `fixtures/`: every script the port has to pass, with what Zig produces for it under `run --port`, which the Swift package copies
  into its test resources.
  `fixtures.sh` regenerates it, and `src/manifest.zig` lists what each script needs.
- `src/coverage.zig`: `coverage <script>...`, which checks that the scripts use everything in the format.
- `src/dump.zig`: `dump <file>`, which prints what's in a database in a form that doesn't depend on file layout.
  `dump --version` and `run --version` name the commit of the original each was built against, and this repository's,
  each with "(with uncommitted changes)" where so, or "unknown" where git can't say, so a record can name them and not a
  time. `build.zig` asks git at every build, and the scripts that build `run.zig` directly give it the commits they used.
- `src/bench.zig`: `bench`, the Zig side of the workloads in `../director/spec/benchmarks.md`. For real numbers, build
  it with `zig build -Doptimize=ReleaseFast --prefix out/release` and run `out/release/bin/bench`.
- `mutants.sh`: makes copies of the Zig original that get copying or rewriting in place wrong, and compaction and
  replication wrong, one place at a time, and shows which scripts notice. It isn't part of the gate, as it's slow.
- `guard-mutants.sh [checkout of a later Zig]`: the same for the port's guards, as `run --port` acts them out. It makes
  copies of `src/run.zig` that get one guard wrong at a time, and runs every fixture with each. It isn't part of the gate
  either.
- `PORT-IMPACT.md`: which scripts rely on what the port changes after its parity gate, and what would happen to each.
  `impact.sh` keeps its lists to what the scripts do, and `impact.sh --prototypes` tries three of the changes on copies of Zig.
- `second-zig.sh <checkout>`: runs all of this against another commit of the Zig implementation, and says what differs.
- `follow.sh <checkout> [commit]`: does that for each commit from the one the fixtures follow up to a later one, says
  what each one moves, and lists every place that names the commit followed ([below](#following-the-original)).
- `upstream.sh`: says how the commit the fixtures follow stands against upstream's HEAD, against the record in
  `tests/upstream.txt`, without failing. `check.sh` runs it.
- `two-processes.sh [reader]`: the original, `src/two_processes.zig`, commits to a file while a reader in another
  process reads it, and holds the reader to every answer being a committed state, in order, up to the last, and to a
  file kept open across a rename of a compacted copy over its name. The original's own reader, `src/reader.zig`, always
  runs; a port's is given as the argument or `XITDB_READER`. `SCRIPT-FORMAT.md` section 15 says what a reader prints.
  The writer and the original's reader name with `--version` the commits they were built from, as `dump` does, and it
  prints both first. `check.sh` runs it.
- `linux-two-processes.sh [--on-volume]`: the same on Linux, with the writer and the original's reader built for aarch64
  Linux by Zig here and run in a container, the image the port's gate uses, which it never pulls. `--on-volume` puts the
  files on a named volume of their own rather than the container's overlay, which matters to a reader that maps.
- `tests/samples/`: databases that programs using the original wrote, which `fixtures.sh` copies to `fixtures/samples/`
  with `dump`'s listing of each, so that the port's reading can be compared with the original's.
- `check.sh`: the gate. It builds everything and checks all of the above, in debug and release builds and across
  all three storage kinds.

It uses the Zig original by path, as `../../xitdb`, without modifying it. It needs Zig 0.17.1. So a clone of this
repository has to sit two folders below a checkout of the original, as `xitdb-swift/conformance` sits beside `xitdb`.
Anywhere else, `check.sh` fails at once with `failed to open ../../xitdb`. A symbolic link at `../../xitdb` to a checkout
works as well.

`.github/workflows/gate.yml` runs `check.sh` on a self-hosted macOS runner at every push and pull request. It checks
this repository out, with its history, at `xitdb-swift/conformance` and clones `xit-vcs/xitdb` at `274418f`, the commit
the fixtures come from, into `xitdb` beside it, which is where `build.zig.zon` looks; when the fixtures follow another
commit, the ref in the workflow moves with them. The runner needs Zig 0.17.1 and git (the Xcode Command Line Tools) on
its PATH, and nothing else.

Commits here carry no `Co-Authored-By` line. `scripts/git-hooks/commit-msg` takes any out, once a clone points git at it,
which is once per clone:

```
git config core.hooksPath scripts/git-hooks
```

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

`tests/zig-commits.txt` says which fixtures need a later commit, which is what's left for the fixes branch now that most
variants have the same bytes on both. That branch is `fix-findings-v3` on `rgb/xitdb`
(https://github.com/rgb/xitdb/tree/fix-findings-v3), on `274418f`, and the commit the file names is its tip when they were
made. `fix-findings-v2`, on `89da8e7`, stays at `bd6abc3` for the commits of this repository that named it.
`PORT-IMPACT.md` has why.

**What the port refuses** doesn't need another Zig, as a guard writes nothing. A script that does it goes in
`tests/zig-only.txt`, which the gate holds to what `run --port` refuses, with a version in `tests/port-variants/` if it pins
something worth having. The fixtures only ever come from `run --port`.

## Following the original

When upstream moves on, the fixtures follow it as a whole, as they did from `6b93af1` to `89da8e7` (D31) and from there to
`274418f` (brief conformance-10). `check.sh` says how the pin stands at every run: `./upstream.sh` asks for upstream's
HEAD with `git ls-remote`, which fetches nothing, and compares it with the pin and with the last line of
`tests/upstream.txt`, the record kept by hand of each time someone held the pin against upstream and what was decided. It
never fails the gate: a pin behind upstream is a fact to act on. Without a network it says so after about ten seconds,
and `XITDB_OFFLINE=1` skips the question. When it says upstream has moved:

```
./follow.sh ../../xitdb <commit>
```

That runs `second-zig.sh` against the commit the manifest names and against every commit after it up to that one, on
the first-parent line, keeping what each wrote, and says, for each commit against the one before:

- which fixtures' files move, with the first byte `detcheck` finds different, and which change their outcome, with why;
- the same for the scripts only for Zig, run without `--port`;
- which failing scripts stop failing, which of the two things each behaviour in `tests/port-differs` does, and what
  changes in `tests/undefined`;
- which seeds `gen` writes differently.

It ends with every file that names the commit followed, and how many times. It changes nothing in either repository,
and differences don't make it fail. It isn't part of the gate, as it builds the harness once for each commit.
`FOLLOW_FROM=6b93af1 ./follow.sh ../../xitdb 89da8e7` shows again what conformance-09 followed. A case in `tests/undefined`
that ended the process and now raises an error has an answer from the original, which a port can be held to: make it a
fixture, or say why not (`PORT-IMPACT.md` has how each was sorted at `274418f`). Then, to move the pin:

1. Put the original at `../../xitdb` at the new commit, and see what fails in `./check.sh`.
2. A script whose outcome changed pins what the old commit did. If the port is to follow the original there, rewrite
   it as a fixture of what the original now does. If the port keeps its own behaviour, it's a difference to sort:
   in `tests/port-differs`, or a variant in `tests/port-variants` with its script in `tests/zig-only.txt`.
   A file the old commit wrote that the new one no longer can is an input in `tests/inputs/`.
3. `./gen-fixed.sh` and `zig-out/bin/longscripts tests/valid` for the scripts they write, commit, `./fixtures.sh`, commit.
4. Move what names the old commit as the one followed: the ref in `.github/workflows/gate.yml`, this README,
   `SCRIPT-FORMAT.md` section 11, and `PORT-IMPACT.md`. What says something was so at the old commit stays.
5. The fixtures in `tests/zig-commits.txt` come from the fixes branch, which follows separately: `second-zig.sh
   --regenerate` once it's on the new commit, under a new branch name, so that the old one stays for older commits here.
6. Add a line to `tests/upstream.txt` with the date, upstream's HEAD and what was decided. Whenever the pin is held
   against upstream and stays, a line says that too.

## Contributing

Issues are welcome, for a script that should exist, a fixture that looks wrong, or a question, but this repository doesn't
take pull requests: the fixtures are generated against the original at a stated commit and the gate decides what lands, so
a change starts as an issue.
