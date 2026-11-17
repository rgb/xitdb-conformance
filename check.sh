#!/bin/sh
# The gate for this repository. It stops at the first problem.
#
# 1. everything builds, gen and longscripts still write the scripts that are committed,
#    gen --port-safe keeps off what the port changes, and reads change no bytes;
# 2. every script runs, twice, and the two files differ only in the commit ID and
#    checksum of each trailer (see src/detcheck.zig for exactly what's checked);
# 3. the storage kind and the optimization level make no difference to the bytes, with the
#    port's guards too, and what's only for Zig really is;
# 4. every script in tests/failing and tests/invalid fails, for the reason in its
#    description, and tests/port-differs still shows what it says about the Zig original;
# 5. dump gives the same text across all of those, doesn't depend on layout, and
#    reports what it can't read;
# 6. bench refuses to give numbers from a debug build, and still runs;
# 7. the hand-written scripts use everything in the format;
# 8. the fixtures haven't drifted from what the scripts produce now, and that check
#    notices drift;
# 9. PORT-IMPACT.md's lists are what the scripts do;
# 10. second-zig.sh finds nothing against this same Zig, and notices what's changed;
# 11. detcheck itself notices a changed byte.

set -eu
cd "$(dirname "$0")"

OUT=out/check
RUN=zig-out/bin/run
DET=zig-out/bin/detcheck

rm -rf "$OUT"
mkdir -p "$OUT"

flip_byte() { # file, byte offset. flips every bit of that byte
    old=$(od -An -tu1 -j "$2" -N 1 "$1" | tr -d ' ')
    printf "$(printf '\\%03o' $((old ^ 255)))" | dd of="$1" bs=1 seek="$2" conv=notrunc 2> /dev/null
}

echo "== build (debug and release)"
zig build
zig build -Doptimize=ReleaseFast --prefix out/release
RELEASE_RUN=out/release/bin/run

echo "== the generated scripts"
./gen-fixed.sh --check

echo "== gen --port-safe keeps off what the port changes"
PORT_SAFE=yes OUT="$OUT/live-port-safe" ./gen-live.sh 20

echo "== reads change no bytes"
# the same seed gives the same writes with or without reads
count=0
for script in tests/generated/reads-*.json; do
    seed=$(basename "$script" .json)
    seed=${seed#reads-}
    zig-out/bin/gen "$seed" "$OUT/plain.json"
    "$RUN" "$script" "$OUT/reads.db"
    "$RUN" "$OUT/plain.json" "$OUT/plain.db"
    "$DET" --ignore-reads "$OUT/reads.db" "$OUT/plain.db" > /dev/null || {
        echo "seed $seed: the script with reads writes a different file from the one without"
        exit 1
    }
    count=$((count + 1))
done
echo "$count scripts give the same file with and without their reads"
# and that check can fail: two different seeds
zig-out/bin/gen 101 "$OUT/plain.json"
zig-out/bin/gen 102 "$OUT/other.json"
"$RUN" "$OUT/plain.json" "$OUT/plain.db"
"$RUN" "$OUT/other.json" "$OUT/other.db"
if "$DET" --ignore-reads "$OUT/plain.db" "$OUT/other.db" > /dev/null 2>&1; then
    echo "detcheck --ignore-reads accepted two different scripts"
    exit 1
fi
echo "detcheck --ignore-reads notices when it isn't only reads"

echo "== the long scripts"
zig-out/bin/longscripts "$OUT/long"
count=0
for script in "$OUT"/long/*.json; do
    name=$(basename "$script")
    cmp -s "$script" "tests/valid/$name" || {
        echo "longscripts no longer writes tests/valid/$name. Run zig-out/bin/longscripts tests/valid"
        exit 1
    }
    count=$((count + 1))
done
if [ "$count" -ne 16 ]; then
    echo "longscripts should write 16 scripts, and it wrote $count"
    exit 1
fi
echo "longscripts still writes the $count scripts that are committed"

echo "== determinism: each script run twice"
for script in scripts/*.json tests/valid/*.json tests/generated/*.json; do
    name=$(basename "$script" .json)
    "$RUN" "$script" "$OUT/$name.a.db"
    "$RUN" "$script" "$OUT/$name.b.db"
    printf '%-24s ' "$name"
    "$DET" "$OUT/$name.a.db" "$OUT/$name.b.db"
done

echo "== storage kinds and optimization levels"
for script in scripts/*.json tests/valid/*.json tests/generated/*.json; do
    name=$(basename "$script" .json)
    "$RUN" "$script" "$OUT/$name.file.db" --kind file
    "$RELEASE_RUN" "$script" "$OUT/$name.release.db"
    "$DET" "$OUT/$name.a.db" "$OUT/$name.file.db" > /dev/null
    "$DET" "$OUT/$name.a.db" "$OUT/$name.release.db" > /dev/null
    # the memory kind has no read-only mode, and has to say so
    if grep -q '"read_only": *true' "$script"; then
        status=0
        "$RUN" "$script" "$OUT/$name.memory.db" --kind memory 2> "$OUT/$name.memory.err" || status=$?
        if [ "$status" -ne 1 ] || ! grep -qF "can't be opened read-only" "$OUT/$name.memory.err"; then
            echo "$name: the memory kind should have refused to open it read-only"
            exit 1
        fi
        echo "$name: buffered_file == file == release, and memory refuses it"
    else
        "$RUN" "$script" "$OUT/$name.memory.db" --kind memory
        "$DET" "$OUT/$name.a.db" "$OUT/$name.memory.db" > /dev/null
        echo "$name: buffered_file == file == memory == release"
    fi
done

expect_failures() { # folder
    count=0
    for script in "$1"/*.json; do
        name=$(basename "$script" .json)
        want=$(sed -n 's/.*"description": "expected failure: \([^"]*\)".*/\1/p' "$script" | head -n 1)
        # the one script whose description can't say, because its description is the problem
        if [ "$name" = "description-wrong-type" ]; then
            want="description must be a string"
        fi
        if [ -z "$want" ]; then
            echo "$name: no expected failure in its description"
            exit 1
        fi
        status=0
        "$RUN" "$script" "$OUT/$name.db" 2> "$OUT/$name.err" || status=$?
        if [ "$status" -ne 1 ]; then
            echo "$name: expected exit status 1, got $status"
            cat "$OUT/$name.err"
            exit 1
        fi
        if ! grep -qF -- "$want" "$OUT/$name.err"; then
            echo "$name: expected a failure with \"$want\", got:"
            cat "$OUT/$name.err"
            exit 1
        fi
        count=$((count + 1))
    done
    echo "$1: $count scripts failed as they should"
}

echo "== what the port does"
count=0
for script in tests/port-variants/*.json; do
    name=$(basename "$script" .json)
    # second-zig.sh runs these
    if grep -q "^$name " tests/zig-commits.txt; then continue; fi
    "$RUN" "$script" "$OUT/$name.a.db" --port
    "$RUN" "$script" "$OUT/$name.b.db" --port
    "$DET" "$OUT/$name.a.db" "$OUT/$name.b.db" > /dev/null
    for kind in file memory; do
        "$RUN" "$script" "$OUT/$name.$kind.db" --kind "$kind" --port
        "$DET" "$OUT/$name.a.db" "$OUT/$name.$kind.db" > /dev/null
    done
    "$RELEASE_RUN" "$script" "$OUT/$name.release.db" --port
    "$DET" "$OUT/$name.a.db" "$OUT/$name.release.db" > /dev/null
    count=$((count + 1))
done
echo "$count variants come out the same on every kind and in a release build"
count=0
while read -r name why; do
    case "$name" in
        "" | "#"*) continue ;;
    esac
    script=
    for dir in scripts tests/valid tests/generated; do
        if [ -f "$dir/$name.json" ]; then script=$dir/$name.json; fi
    done
    if [ -z "$script" ]; then
        echo "tests/zig-only.txt names $name, and there's no such script"
        exit 1
    fi
    status=0
    "$RUN" "$script" "$OUT/zig-only.db" --port 2> /dev/null > /dev/null || status=$?
    if [ "$status" -ne 1 ]; then
        echo "$name is in tests/zig-only.txt, and run --port doesn't refuse it, so it should be a fixture"
        exit 1
    fi
    count=$((count + 1))
done < tests/zig-only.txt
echo "$count scripts are only for Zig, and run --port refuses each of them"

echo "== scripts that must fail"
expect_failures tests/failing
expect_failures tests/invalid

echo "== both kinds of offset map give the same target"
count=0
for script in tests/valid/*.json tests/generated/compact-*.json; do
    grep -q '"offset_map": *"memory"' "$script" || continue
    name=$(basename "$script" .json)
    sed 's/"offset_map": *"memory"/"offset_map": "disk"/' "$script" > "$OUT/disk.json"
    "$RUN" "$OUT/disk.json" "$OUT/$name.disk.db"
    "$DET" "$OUT/$name.a.db" "$OUT/$name.disk.db" > /dev/null || {
        echo "$name: the offset map changed what compaction wrote"
        exit 1
    }
    rm -f "$OUT/$name.disk.db"* "$OUT/$name.disk".*.db
    count=$((count + 1))
done
if [ "$count" -lt 12 ]; then
    echo "only $count scripts compact with the memory offset map, which is fewer than there should be"
    exit 1
fi
echo "$count scripts give the same files with the disk-backed offset map"

echo "== what the port corrects"
# what these say about Zig has to stay true, and they have to stay out of everything else
count=0
for script in tests/port-differs/*.zig.json; do
    name=$(basename "$script" .zig.json)
    port=tests/port-differs/$name.port.json
    [ -f "$port" ] || {
        echo "$name has no script for what the port does"
        exit 1
    }
    "$RUN" "$script" "$OUT/differs.db" --allow-port-differences
    status=0
    "$RUN" "$port" "$OUT/differs.db" --allow-port-differences 2> /dev/null || status=$?
    if [ "$status" -ne 1 ]; then
        echo "$name: what the port does shouldn't pass on the Zig original, and its exit status is $status"
        exit 1
    fi
    for refused in "$script" "$port"; do
        status=0
        "$RUN" "$refused" "$OUT/differs.db" 2> "$OUT/differs.err" || status=$?
        if [ "$status" -ne 1 ] || ! grep -qE "the port corrects|expect_error can" "$OUT/differs.err"; then
            echo "$refused should be refused without --allow-port-differences, and its exit status is $status:"
            head -n 2 "$OUT/differs.err"
            exit 1
        fi
    done
    count=$((count + 1))
done
if [ "$count" -ne 7 ]; then
    echo "tests/port-differs should have 7 behaviours, and it has $count"
    exit 1
fi
echo "$count behaviours: Zig does what they say, and a valid script can't use them"

echo "== dump"
DUMP=zig-out/bin/dump
count=0
for script in scripts/*.json tests/valid/*.json tests/generated/*.json; do
    name=$(basename "$script" .json)
    # each of the other databases, if it has any, the same way
    for database in "" $(grep -o '^    "[A-Za-z0-9_]*": {"file_id"' "$OUT/$name.a.db.sidecar.json" | sed 's/^    "\([^"]*\)".*/\1/' | grep -v '^main$'); do
        suffix=${database:+.$database}
        # one can be left in no state to read by a script that means to, and it's there to compare
        status=0
        "$DUMP" "$OUT/$name.a$suffix.db" > "$OUT/$name.a$suffix.txt" 2> /dev/null || status=$?
        if [ "$status" -ne 0 ] && ! grep -qx "$name ${database:-main}" tests/dump/unreadable.txt; then
            echo "$name: dump can't read ${database:-main}"
            exit 1
        fi
        for other in b file memory release; do
            [ -f "$OUT/$name.$other$suffix.db" ] || continue
            "$DUMP" "$OUT/$name.$other$suffix.db" > "$OUT/$name.$other$suffix.txt" 2> /dev/null || true
            cmp -s "$OUT/$name.a$suffix.txt" "$OUT/$name.$other$suffix.txt" || {
                echo "$name: dump of ${database:-main} differs between a and $other"
                exit 1
            }
        done
    done
    count=$((count + 1))
done
echo "$count scripts dump without errors, and the same across runs, storage kinds and builds"
for expected in tests/dump/expected/*.txt; do
    name=$(basename "$expected" .txt)
    cmp -s "$OUT/$name.a.txt" "$expected" || {
        echo "$name: dump differs from $expected"
        exit 1
    }
done
echo "dump still prints what it should for $(ls tests/dump/expected | wc -l | tr -d ' ') scripts"
"$RUN" tests/dump/same-content-a.json "$OUT/same-a.db"
"$RUN" tests/dump/same-content-b.json "$OUT/same-b.db"
if cmp -s "$OUT/same-a.db" "$OUT/same-b.db"; then
    echo "same-content-a and same-content-b should be different files"
    exit 1
fi
"$DUMP" "$OUT/same-a.db" > "$OUT/same-a.txt"
"$DUMP" "$OUT/same-b.db" > "$OUT/same-b.txt"
cmp -s "$OUT/same-a.txt" "$OUT/same-b.txt" || {
    echo "the same content in different bytes should dump the same"
    diff "$OUT/same-a.txt" "$OUT/same-b.txt" | head -20
    exit 1
}
echo "the same content in different bytes dumps the same"
# the value slot of the worked example, whose last byte is the 42
cp "$OUT/worked-example.a.db" "$OUT/changed.db"
flip_byte "$OUT/changed.db" 407
"$DUMP" "$OUT/changed.db" > "$OUT/changed.txt"
if cmp -s "$OUT/worked-example.a.txt" "$OUT/changed.txt"; then
    echo "dump didn't notice a changed value"
    exit 1
fi
echo "a changed value dumps differently"
"$RUN" tests/dump/dangling.json "$OUT/dangling.db"
status=0
"$DUMP" "$OUT/dangling.db" > "$OUT/dangling.txt" 2> /dev/null || status=$?
if [ "$status" -ne 1 ] || ! grep -q "error EndOfStream" "$OUT/dangling.txt"; then
    echo "dump should have reported the dangling slot, but its exit status is $status"
    exit 1
fi
echo "a slot pointing past the end of the file is reported"

echo "== what tests/undefined shows still happens"
# none of this is among the fixtures. if one of these stops happening, the Zig original
# has changed, and SCRIPT-FORMAT.md's table of undefined uses needs to change too.
count=0
while read -r kind name want text; do
    case "$kind" in
        script | wrapper) ;;
        *) continue ;;
    esac
    code=0
    if [ "$kind" = script ]; then
        "$RUN" "tests/undefined/$name.json" "$OUT/undefined.db" > /dev/null 2> "$OUT/undefined.err" || code=$?
    else
        zig-out/bin/undefined-wrappers "$name" > /dev/null 2> "$OUT/undefined.err" || code=$?
    fi
    # a case with no text prints nothing to look for
    if [ "$code" -ne "$want" ] || { [ -n "$text" ] && ! grep -qF -- "$text" "$OUT/undefined.err"; }; then
        echo "$kind $name: expected exit status $want with \"$text\", got $code:"
        head -n 3 "$OUT/undefined.err"
        exit 1
    fi
    count=$((count + 1))
done < tests/undefined/expected.txt
if [ "$count" -ne 28 ]; then
    echo "tests/undefined/expected.txt should have 28 cases, and it has $count"
    exit 1
fi
echo "$count cases do what tests/undefined/expected.txt says"

echo "== bench still works, and writes the size run does"
BENCH=zig-out/bin/bench
status=0
"$BENCH" > /dev/null 2> "$OUT/bench.err" || status=$?
if [ "$status" -ne 1 ] || ! grep -qF "its numbers would mean nothing" "$OUT/bench.err"; then
    echo "bench should refuse to give numbers from a debug build"
    exit 1
fi
"$BENCH" --divide 1000 > "$OUT/bench.txt"
lines=$(wc -l < "$OUT/bench.txt" | tr -d ' ')
if [ "$lines" -ne 57 ]; then
    echo "bench should print 57 lines, and it printed $lines"
    exit 1
fi
echo "bench refuses a debug build, and prints its 57 lines"
# the file size is what the Swift side is held to, so bench has to mean what it says.
# these scripts are its workloads, spelled out as the spec spells them.
for line in "map_insert 100 memory" "map_insert 100 buffered_file" "map_insert 10 file" "list_append 1000 memory" "list_append 1000 buffered_file" "map_transactions 2 memory" "map_transactions 2 buffered_file" "linked_append 100 memory" "linked_append 100 buffered_file" "linked_append 10 file" "sorted_insert 100 memory" "sorted_insert 100 buffered_file" "sorted_insert 10 file"; do
    set -- $line
    "$RUN" "tests/bench/$1-$2.json" "$OUT/bench-$1-$2-$3.db" --kind "$3"
    from_run=$(sed -n 's/.*"file_size": \([0-9]*\).*/\1/p' "$OUT/bench-$1-$2-$3.db.sidecar.json")
    from_bench=$(grep "\"workload\": \"$1\", \"phase\": \"write\", \"kind\": \"$3\"" "$OUT/bench.txt" | sed -n 's/.*"file_size": \([0-9]*\).*/\1/p')
    if [ -z "$from_run" ] || [ "$from_run" != "$from_bench" ]; then
        echo "$1 at $2 on $3: bench says the file is $from_bench bytes, and run says $from_run"
        exit 1
    fi
done
echo "bench's file sizes are what run gets for the same operations, on 13 workloads and kinds"
# from 10,000 on, a sorted key is a byte record and not in a slot, which those are too small to
# reach, and this script is too big to keep
"$BENCH" --divide 9 --only sorted_insert > "$OUT/bench-sorted.txt"
awk 'BEGIN {
    printf "{\"format\":\"xitdb-script/1\",\"hash_size\":20,\"hash_id\":\"sha1\",\"file_id\":\"0011223344556677\",\"ops\":[{\"op\":\"write_path\",\"on\":\"root\",\"path\":[\"array_list_init\",\"array_list_append\",{\"sorted_map_init\":{}},{\"ctx\":{\"as\":\"c\",\"ops\":["
    for (i = 0; i < 11111; i++) {
        printf "%s{\"op\":\"write_path\",\"on\":\"c\",\"path\":[{\"sorted_map_get\":{\"value\":\"key-%d\"}},{\"write\":{\"uint\":%d}}]}", (i > 0 ? "," : ""), i, i
    }
    print "]}}]}]}"
}' > "$OUT/bench-sorted.json"
for kind in memory buffered_file; do
    "$RUN" "$OUT/bench-sorted.json" "$OUT/bench-sorted-$kind.db" --kind "$kind"
    from_run=$(sed -n 's/.*"file_size": \([0-9]*\).*/\1/p' "$OUT/bench-sorted-$kind.db.sidecar.json")
    from_bench=$(grep "\"phase\": \"write\", \"kind\": \"$kind\", \"n\": 11111," "$OUT/bench-sorted.txt" | sed -n 's/.*"file_size": \([0-9]*\).*/\1/p')
    if [ -z "$from_run" ] || [ "$from_run" != "$from_bench" ]; then
        echo "sorted_insert at 11111 on $kind: bench says the file is $from_bench bytes, and run says $from_run"
        exit 1
    fi
done
echo "and on sorted_insert with keys past 10,000, which are byte records"
# the file size of map_compact and replicate is another database's, which run writes beside the first
other_size_is() { # workload, which database, script, kind, what bench printed, what it's about
    "$RUN" "$3" "$OUT/bench-other.db" --kind "$4"
    from_run=$(wc -c < "$OUT/bench-other.$2.db" | tr -d ' ')
    from_bench=$(grep "\"workload\": \"$1\", \"phase\": \"write\", \"kind\": \"$4\"" "$5" | sed -n 's/.*"file_size": \([0-9]*\).*/\1/p')
    if [ -z "$from_bench" ] || [ "$from_run" != "$from_bench" ]; then
        echo "$1, $6 on $4: bench says the $2 is $from_bench bytes, and run says $from_run"
        exit 1
    fi
}
other_size_is map_compact target tests/bench/map_compact-2.json memory "$OUT/bench.txt" "t = 2"
other_size_is map_compact target tests/bench/map_compact-2.json buffered_file "$OUT/bench.txt" "t = 2"
other_size_is map_compact target tests/bench/map_compact-1.json file "$OUT/bench.txt" "t = 1"
other_size_is replicate replica tests/bench/replicate-2.json memory "$OUT/bench.txt" "t = 2"
other_size_is replicate replica tests/bench/replicate-2.json buffered_file "$OUT/bench.txt" "t = 2"
other_size_is replicate replica tests/bench/replicate-1.json file "$OUT/bench.txt" "t = 1"
# with so few keys the trie is one block, and these scripts are too big to keep. each is t
# transactions with the committed size noted, `more` transactions, and what's in $TAIL
transactions_script() { # t, more, output
    awk -v t="$1" -v more="$2" 'BEGIN {
        printf "{\"format\":\"xitdb-script/1\",\"hash_size\":20,\"hash_id\":\"sha1\",\"file_id\":\"0011223344556677\",\"ops\":["
        for (j = 0; j < t + more; j++) {
            if (more > 0 && j == t) printf "{\"op\":\"committed_size\",\"as\":\"size_t\"},"
            printf "{\"op\":\"read_path_slot\",\"on\":\"root\",\"path\":[{\"array_list_get\":-1}],\"as\":\"last\"},{\"op\":\"write_path\",\"on\":\"root\",\"path\":[\"array_list_init\",\"array_list_append\",{\"write\":{\"slot\":{\"var\":\"last\"}}},{\"hash_map_init\":{}},{\"ctx\":{\"as\":\"c\",\"ops\":["
            for (i = 10 * j; i < 10 * j + 10; i++) {
                printf "%s{\"op\":\"write_path\",\"on\":\"c\",\"path\":[{\"hash_map_get\":{\"value\":{\"sha1\":\"key-%d\"}}},{\"write\":{\"uint\":%d}}]}", (i > 10 * j ? "," : ""), i, i
            }
            printf "]}}]},"
        }
        print ENVIRON["TAIL"] "]}"
    }' > "$3"
}
TAIL='{"op":"compact","into":"target","file_id":"0011223344556677","offset_map":"memory"}'
export TAIL
transactions_script 200 0 "$OUT/bench-compact-200.json"
transactions_script 20 0 "$OUT/bench-compact-20.json"
TAIL='{"op":"create_database","name":"replica","file_id":"0011223344556677"},{"op":"read_committed","start":0,"end":{"var":"size_t"},"as":"full"},{"op":"use","name":"replica"},{"op":"apply_replicated","start":0,"bytes":"full"},{"op":"committed_size","expect":{"var":"size_t"}},{"op":"replica_state","as":"state"},{"op":"use","name":"main"},{"op":"replication_start","state":"state","as":"start","expect":{"var":"size_t"}},{"op":"committed_size","as":"end"},{"op":"read_committed","start":{"var":"start"},"end":{"var":"end"},"as":"incremental"},{"op":"use","name":"replica"},{"op":"apply_replicated","start":{"var":"start"},"bytes":"incremental"},{"op":"committed_size","expect":{"var":"end"}}'
transactions_script 200 10 "$OUT/bench-replicate-200.json"
transactions_script 20 10 "$OUT/bench-replicate-20.json"
"$BENCH" --divide 10 --only map_compact > "$OUT/bench-compact.txt"
"$BENCH" --divide 10 --only replicate > "$OUT/bench-replicate.txt"
other_size_is map_compact target "$OUT/bench-compact-200.json" memory "$OUT/bench-compact.txt" "t = 200"
other_size_is map_compact target "$OUT/bench-compact-200.json" buffered_file "$OUT/bench-compact.txt" "t = 200"
other_size_is map_compact target "$OUT/bench-compact-20.json" file "$OUT/bench-compact.txt" "t = 20"
other_size_is replicate replica "$OUT/bench-replicate-200.json" memory "$OUT/bench-replicate.txt" "t = 200"
other_size_is replicate replica "$OUT/bench-replicate-200.json" buffered_file "$OUT/bench-replicate.txt" "t = 200"
other_size_is replicate replica "$OUT/bench-replicate-20.json" file "$OUT/bench-replicate.txt" "t = 20"
echo "and on map_compact's target and replicate's replica, at t = 2 and 1, and at t = 200 and 20"

echo "== coverage of the format by the hand-written scripts"
COVERAGE=zig-out/bin/coverage
"$COVERAGE" scripts/*.json tests/valid/*.json
# it can fail both ways: too little used, and something used that isn't on its list
status=0
"$COVERAGE" tests/valid/worked-example.json 2> "$OUT/coverage.err" || status=$?
if [ "$status" -ne 1 ] || ! grep -qF "nothing uses op:writer" "$OUT/coverage.err"; then
    echo "coverage should have noticed what one script doesn't use"
    exit 1
fi
echo "coverage notices what's missing"
cat > "$OUT/coverage-extra.json" <<'SCRIPT'
{ "format": "xitdb-script/1", "hash_size": 20, "hash_id": null, "file_id": "0000000000000001",
  "ops": [{ "op": "slot", "on": "root", "expect": { "tag": "index" } }] }
SCRIPT
status=0
"$COVERAGE" scripts/*.json tests/valid/*.json "$OUT/coverage-extra.json" 2> "$OUT/coverage.err" || status=$?
if [ "$status" -ne 1 ] || ! grep -qF "expect_tag:index is used, but it isn't on this tool's list" "$OUT/coverage.err"; then
    echo "coverage should have noticed something that isn't on its list"
    exit 1
fi
echo "coverage notices what's not on its list"

echo "== the fixtures"
./fixtures.sh --check
# the scripts that go on from what a failed copy at 0 leaves, which a storage that replaces the file on a full
# copy leaves out (D55). the manifest finds them from what the run did, so a new one shows up here for review
cut_short=$(grep '"cut_short_copy"' fixtures/manifest.json | sed 's/^ *{"name": "\([^"]*\)".*/\1/' | sort | tr '\n' ' ')
if [ "$cut_short" != "recover-without-first-commit--port replicate-copy-cut-short replicate-failed-first-sync " ]; then
    echo "the manifest marks these as cut_short_copy, and not the three it should: $cut_short"
    exit 1
fi
echo "the manifest marks the three scripts that go on from a failed copy"

echo "== the fixture check notices drift"
COPY="$OUT/fixtures-copy"
fresh_copy() {
    rm -rf "$COPY"
    cp -R fixtures "$COPY"
}
edit_file() { # file, sed expression
    sed "$2" "$1" > "$1.edited"
    mv "$1.edited" "$1"
}
expect_drift() { # what was changed in the copy, expected message
    if FIXTURES="$COPY" ./fixtures.sh --check > "$OUT/drift.out" 2>&1; then
        echo "the fixture check accepted $1"
        exit 1
    fi
    if ! grep -qF -- "$2" "$OUT/drift.out"; then
        echo "the fixture check rejected $1 for the wrong reason:"
        cat "$OUT/drift.out"
        exit 1
    fi
    echo "$1 is rejected"
}
fresh_copy
flip_byte "$COPY/valid/worked-example.db" 395
expect_drift "a changed byte in an expected file" "worked-example has drifted"
fresh_copy
flip_byte "$COPY/valid/worked-example.db" 417
expect_drift "a commit ID that doesn't match its checksum" "worked-example has drifted"
fresh_copy
edit_file "$COPY/valid/worked-example.db.sidecar.json" 's/"committed_size": 433/"committed_size": 434/'
expect_drift "a wrong size in a sidecar" "worked-example has drifted"
fresh_copy
edit_file "$COPY/valid/worked-example.db.sidecar.json" 's/"initial_size": 57,/"initial_size":  57,/'
expect_drift "a change to a sidecar's layout" "worked-example's sidecar has drifted"
fresh_copy
flip_byte "$COPY/inputs/v1-history.db" 100
expect_drift "a changed input" "the input v1-history.db differs"
fresh_copy
touch "$COPY/inputs/not-an-input.db"
expect_drift "an extra input" "has no source in tests/inputs"
fresh_copy
flip_byte "$COPY/samples/haxy/users-index.db" 100
expect_drift "a changed sample" "the sample haxy/users-index.db differs"
fresh_copy
printf ' ' >> "$COPY/samples/haxy/users-index.txt"
expect_drift "a changed listing of a sample" "dump's listing of the sample haxy/users-index has drifted"
fresh_copy
printf ' ' >> "$COPY/valid/worked-example.json"
expect_drift "a changed script" "worked-example differs from the script"
fresh_copy
rm "$COPY/valid/worked-example.db"
expect_drift "a missing expected file" "worked-example has no expected file"
fresh_copy
rm "$COPY/valid/worked-example.json"
expect_drift "a missing script" "worked-example is missing"
fresh_copy
rm "$COPY/failing/wrong-uint.json"
expect_drift "a missing failing script" "wrong-uint is missing"
fresh_copy
touch "$COPY/valid/not-a-script.json"
expect_drift "an extra script" "has no source script"
fresh_copy
touch "$COPY/failing/not-a-script.json"
expect_drift "an extra failing script" "has no source script"
fresh_copy
edit_file "$COPY/manifest.json" 's/"name": "hash-size-8", \(.*\)"collections": \["hash_map"\]/"name": "hash-size-8", \1"collections": []/'
expect_drift "wrong collections in the manifest" "manifest.json has drifted"
fresh_copy
edit_file "$COPY/manifest.json" 's/"zig_commit": "[0-9a-f]*"/"zig_commit": "0000"/'
expect_drift "a wrong Zig commit in the manifest" "manifest.json has drifted"
fresh_copy
edit_file "$COPY/manifest.json" 's/"conformance_commit": "[0-9a-f]*"/"conformance_commit": "0123456789"/'
expect_drift "a conformance commit from elsewhere" "isn't in this branch's history"
fresh_copy
printf ' ' >> "$COPY/README.md"
expect_drift "a changed README" "README.md has drifted"
# what the manifest names is what's here, and the other way round. this one is what it named in conformance-09,
# a target that the port's guard refused to compact into before it made it, so it was in the script and not on disk
fresh_copy
edit_file "$COPY/manifest.json" 's|"v1_one": "valid/compact-sliced-history--port.v1_one.db"|&, "v1_one_target": "valid/compact-sliced-history--port.v1_one_target.db"|'
expect_drift "a manifest naming a database the run didn't leave" "the manifest names valid/compact-sliced-history--port.v1_one_target.db, which isn't in"
fresh_copy
touch "$COPY/notes.txt"
expect_drift "a file nothing names" "notes.txt is neither named by the manifest nor one of the files the README says are here"
fresh_copy
mkdir "$COPY/older"
expect_drift "a folder nothing names" "fixtures-copy/older is neither named by the manifest nor one of the files the README says are here"
# and the manifest goes by the sidecar, which is what the run left, so it won't name a file that isn't there
fresh_copy
rm "$COPY/valid/compact-sliced-history--port.v1_one.db"
here=$PWD
if (cd "$COPY" && "$here/zig-out/bin/manifest" x x x "$here/tests/zig-commits.txt" valid/compact-sliced-history--port.json) > "$OUT/manifest.out" 2>&1; then
    echo "the manifest named a database that isn't there"
    exit 1
fi
if ! grep -qF "the manifest would name valid/compact-sliced-history--port.v1_one.db, which isn't here" "$OUT/manifest.out"; then
    echo "the manifest refused a database that isn't there for the wrong reason:"
    cat "$OUT/manifest.out"
    exit 1
fi
echo "the manifest names only what's there"
rm -rf "$COPY"

echo "== the pin against upstream"
# it says how the pin stands and never fails: a pin behind upstream is a fact to act on, not a broken gate
./upstream.sh
# each of its answers leaves the check passing. a repository of its own stands in for upstream, sharing the
# original's objects, so none of this needs the network
UP="$OUT/upstream"
rm -rf "$UP"
git clone -q --bare --shared ../../xitdb "$UP"
pin=$(sed -n 's/^  "zig_commit": "\([0-9a-f]*\)",$/\1/p' fixtures/manifest.json)
past=$(GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@example.invalid GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@example.invalid \
    git -C "$UP" commit-tree "$pin^{tree}" -p "$pin" -m "a commit past the pin")
expect_upstream() { # what it should say, then what to set for it
    want=$1
    shift
    said=$(env "$@" ./upstream.sh) || {
        echo "upstream.sh failed, with $*, and it never should"
        exit 1
    }
    case "$said" in
        *"$want"*) ;;
        *)
            echo "upstream.sh should have said \"$want\", with $*, and it said: $said"
            exit 1
            ;;
    esac
}
git -C "$UP" update-ref refs/heads/main "$pin"
git -C "$UP" symbolic-ref HEAD refs/heads/main
expect_upstream "the pin is upstream's HEAD" XITDB_UPSTREAM="$UP"
git -C "$UP" update-ref refs/heads/main "$past"
expect_upstream "and not in" XITDB_UPSTREAM="$UP"
{ cat tests/upstream.txt; echo "2026-11-17 $past stays at the pin, for this check"; } > "$OUT/upstream.txt"
expect_upstream "known since 2026-11-17" XITDB_UPSTREAM="$UP" XITDB_UPSTREAM_RECORD="$OUT/upstream.txt"
expect_upstream "couldn't be reached" XITDB_UPSTREAM="$OUT/no-such-repository"
expect_upstream "wasn't asked" XITDB_OFFLINE=1
rm -rf "$UP"
echo "upstream.sh says each of its answers, a pin behind upstream among them, and none of them fails the check"

echo "== what the port will change"
./impact.sh --check
# and that it can notice, as a list out of date is the failure it's for
sed 's/^- `tests\/valid`: every-construct-sorted (1)$/- `tests\/valid`: nothing/' PORT-IMPACT.md > "$OUT/impact-edited.md"
if cmp -s PORT-IMPACT.md "$OUT/impact-edited.md"; then
    echo "the list this expected to change isn't in PORT-IMPACT.md any more"
    exit 1
fi
if IMPACT_DOC="$OUT/impact-edited.md" ./impact.sh --check > "$OUT/impact.out" 2>&1; then
    echo "impact.sh didn't notice a list out of date"
    exit 1
fi
if ! grep -qF "aren't what the scripts do" "$OUT/impact.out"; then
    echo "impact.sh rejected a list out of date for the wrong reason:"
    cat "$OUT/impact.out"
    exit 1
fi
echo "impact.sh notices a list out of date"

echo "== second-zig.sh"
# against this same Zig commit, where there's nothing for it to find
SECOND_ZIG_OUT=$OUT/second-zig ./second-zig.sh "$(cd ../../xitdb && pwd)" > "$OUT/second-zig.txt"
expect_report() { # text that should be in the report
    if ! grep -qF -- "$1" "$OUT/second-zig.txt"; then
        echo "second-zig.sh should have said \"$1\", and it said:"
        cat "$OUT/second-zig.txt"
        exit 1
    fi
    echo "it says: $1"
}
# what's from another Zig commit isn't compared with this one
from_elsewhere=$(grep -c '^[^#]' tests/zig-commits.txt || true)
valid_fixtures=$(($(find fixtures/valid -name '*.db.sidecar.json' | wc -l | tr -d ' ') - from_elsewhere))
failing_fixtures=$(find fixtures/failing -name '*.json' | wc -l | tr -d ' ')
generated=$(find tests/generated -name '*.json' | wc -l | tr -d ' ')
expect_report "$valid_fixtures with the same bytes, 0 with different bytes, 0 that fail"
expect_report "$failing_fixtures still fail, and 0 don't"
expect_report "$(grep -c '^[^#]' tests/zig-only.txt) run on Zig, and 0 fail"
expect_report "6 as the original does, and 0 as the port does"
expect_report "28 as they were, and 0 changed"
expect_report "$generated scripts the same, and 0 different"
# and what it does with a changed fixture, in copies of what it would change
COPY="$OUT/fixtures-second"
rm -rf "$COPY"
cp -R fixtures "$COPY"
flip_byte "$COPY/valid/worked-example.db" 395
FIXTURES="$COPY" SECOND_ZIG_OUT=$OUT/second-zig ./second-zig.sh "$(cd ../../xitdb && pwd)" > "$OUT/second-zig.txt"
expect_report "different: worked-example"
rm -rf "$COPY" "$OUT/second-zig"

echo "== detcheck notices changes"
# a corrupt file can come from a script's raw_write too, but the same in both runs, so
# detcheck has to accept that a trailer can be gone, and nothing more
A="$OUT/01-list-root-hash-map.a.db"
B="$OUT/01-list-root-hash-map.b.db"
expect_detcheck_failure() { # byte offset, what's there, expected message
    corrupt="$OUT/corrupt.db"
    cp "$B" "$corrupt"
    cp "$B.sidecar.json" "$corrupt.sidecar.json"
    flip_byte "$corrupt" "$1"
    if "$DET" "$A" "$corrupt" > /dev/null 2> "$OUT/det.err"; then
        echo "detcheck accepted a change in $2"
        exit 1
    fi
    if ! grep -qF -- "$3" "$OUT/det.err"; then
        echo "detcheck rejected a change in $2 for the wrong reason:"
        cat "$OUT/det.err"
        exit 1
    fi
    echo "a change in $2 is rejected"
}
# the first commit's trailer ends at its committed size
first_end=$(sed -n 's/.*"committed_size": \([0-9]*\), "commit_id": "[0-9a-f]*".*/\1/p' "$B.sidecar.json" | head -n 1)
trailer=$((first_end - 25))
expect_detcheck_failure 70 "the data" "isn't part of a trailer's commit ID or checksum"
expect_detcheck_failure 21 "the padding before the root header" "isn't part of a trailer's commit ID or checksum"
expect_detcheck_failure 31 "the root header" "the root header's size is not the last committed size"
expect_detcheck_failure "$((trailer + 1))" "a trailer's root slot" "checksum"
expect_detcheck_failure "$((trailer + 9))" "a trailer's commit ID" "commit ID"
expect_detcheck_failure "$((trailer + 17))" "a trailer's checksum" "checksum"
# the same for a trailer past the committed size, which is checked too
A="$OUT/recovery-lost-commit-at-end.a.db"
B="$OUT/recovery-lost-commit-at-end.b.db"
past=$(wc -c < "$B" | tr -d ' ')
expect_detcheck_failure "$((past - 25 + 9))" "a commit ID past the committed size" "commit ID"
expect_detcheck_failure "$((past - 1))" "a checksum past the committed size" "checksum"
expect_detcheck_failure "$((past - 100))" "other bytes past the committed size" "isn't part of a trailer's commit ID or checksum"

echo "== all checks passed"
