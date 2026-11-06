#!/bin/sh
# The gate for this repository. It stops at the first problem.
#
# 1. everything builds, gen and longscripts still write the scripts that are committed,
#    and reads change no bytes;
# 2. every script runs, twice, and the two files differ only in the commit ID and
#    checksum of each trailer (see src/detcheck.zig for exactly what's checked);
# 3. the storage kind and the optimization level make no difference to the bytes;
# 4. every script in tests/failing and tests/invalid fails, for the reason in its
#    description, and tests/port-differs still shows what it says about the Zig original;
# 5. dump gives the same text across all of those, doesn't depend on layout, and
#    reports what it can't read;
# 6. bench refuses to give numbers from a debug build, and still runs;
# 7. the hand-written scripts use everything in the format;
# 8. the fixtures haven't drifted from what the scripts produce now, and that check
#    notices drift;
# 9. detcheck itself notices a changed byte.

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
if [ "$count" -ne 6 ]; then
    echo "longscripts should write 6 scripts, and it wrote $count"
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

echo "== scripts that must fail"
expect_failures tests/failing
expect_failures tests/invalid

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
if [ "$count" -ne 4 ]; then
    echo "tests/port-differs should have 4 behaviours, and it has $count"
    exit 1
fi
echo "$count behaviours: Zig does what they say, and a valid script can't use them"

echo "== dump"
DUMP=zig-out/bin/dump
count=0
for script in scripts/*.json tests/valid/*.json tests/generated/*.json; do
    name=$(basename "$script" .json)
    "$DUMP" "$OUT/$name.a.db" > "$OUT/$name.a.txt"
    for other in b file memory release; do
        [ -f "$OUT/$name.$other.db" ] || continue
        "$DUMP" "$OUT/$name.$other.db" > "$OUT/$name.$other.txt"
        cmp -s "$OUT/$name.a.txt" "$OUT/$name.$other.txt" || {
            echo "$name: dump differs between a and $other"
            exit 1
        }
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
flip_byte "$OUT/changed.db" 412
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
expect_undefined() { # script, exit status, what it says
    status=0
    "$RUN" "tests/undefined/$1.json" "$OUT/undefined.db" 2> "$OUT/undefined.err" || status=$?
    if [ "$status" -ne "$2" ] || ! grep -qF -- "$3" "$OUT/undefined.err"; then
        echo "$1: expected exit status $2 with \"$3\", got $status:"
        head -n 3 "$OUT/undefined.err"
        exit 1
    fi
    echo "$1: $3"
}
expect_undefined frozen-clone-linked-read 1 "unexpected error InvalidBTreeNode"
expect_undefined frozen-clone-sorted-read 1 "unexpected error InvalidBTreeNode"
expect_undefined frozen-clone-linked-append 134 "start index 4 is larger than end index 2"
expect_undefined concat-stale-slot 134 "is larger than end index"
# the same through the collection wrappers alone
expect_wrappers() { # exit status, what it says, cases
    wanted_status=$1
    wanted_text=$2
    shift 2
    for case in "$@"; do
        status=0
        zig-out/bin/undefined-wrappers "$case" > /dev/null 2> "$OUT/undefined.err" || status=$?
        if [ "$status" -ne "$wanted_status" ] || ! grep -qF -- "$wanted_text" "$OUT/undefined.err"; then
            echo "wrappers: $case: expected exit status $wanted_status with \"$wanted_text\", got $status:"
            head -n 3 "$OUT/undefined.err"
            exit 1
        fi
    done
    echo "wrappers, $wanted_text: $*"
}
expect_wrappers 134 "is larger than end index" concat_then_clone concat_two_wrappers concat_slot_read_before concat_old_map_wrapper frozen_clone_append frozen_clone_remove kept_across_transactions
expect_wrappers 134 "integer overflow" sorted_frozen_clone_remove counted_frozen_clone_remove
expect_wrappers 1 "InvalidBTreeNode" frozen_clone_read sorted_frozen_clone_read
expect_wrappers 0 "finished" array_frozen_clone array_frozen_clone_slice hash_frozen_clone no_problem_without_freeze

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
if [ "$lines" -ne 14 ]; then
    echo "bench should print 14 lines, and it printed $lines"
    exit 1
fi
echo "bench refuses a debug build, and prints its 14 lines"
# the file size is what the Swift side is held to, so bench has to mean what it says.
# these scripts are its workloads, spelled out as the spec spells them.
for line in "map_insert 100 memory" "map_insert 100 buffered_file" "map_insert 10 file" "list_append 1000 memory" "list_append 1000 buffered_file" "map_transactions 2 memory" "map_transactions 2 buffered_file"; do
    set -- $line
    "$RUN" "tests/bench/$1-$2.json" "$OUT/bench-$1-$2-$3.db" --kind "$3"
    from_run=$(sed -n 's/.*"file_size": \([0-9]*\).*/\1/p' "$OUT/bench-$1-$2-$3.db.sidecar.json")
    from_bench=$(grep "\"workload\": \"$1\", \"phase\": \"write\", \"kind\": \"$3\"" "$OUT/bench.txt" | sed -n 's/.*"file_size": \([0-9]*\).*/\1/p')
    if [ -z "$from_run" ] || [ "$from_run" != "$from_bench" ]; then
        echo "$1 at $2 on $3: bench says the file is $from_bench bytes, and run says $from_run"
        exit 1
    fi
done
echo "bench's file sizes are what run gets for the same operations, on 7 workloads and kinds"

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
flip_byte "$COPY/valid/worked-example.db" 400
expect_drift "a changed byte in an expected file" "worked-example has drifted"
fresh_copy
flip_byte "$COPY/valid/worked-example.db" 422
expect_drift "a commit ID that doesn't match its checksum" "worked-example has drifted"
fresh_copy
edit_file "$COPY/valid/worked-example.db.sidecar.json" 's/"committed_size": 438/"committed_size": 439/'
expect_drift "a wrong size in a sidecar" "worked-example has drifted"
fresh_copy
edit_file "$COPY/valid/worked-example.db.sidecar.json" 's/"initial_size": 62,/"initial_size":  62,/'
expect_drift "a change to a sidecar's layout" "worked-example's sidecar has drifted"
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
rm -rf "$COPY"

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
expect_detcheck_failure 21 "the root header" "isn't part of a trailer's commit ID or checksum"
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
