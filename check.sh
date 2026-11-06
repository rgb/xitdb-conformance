#!/bin/sh
# The gate for this repository. It stops at the first problem.
#
# 1. everything builds;
# 2. every script runs, twice, and the two files differ only in the commit ID and
#    checksum of each trailer (see src/detcheck.zig for exactly what's checked);
# 3. the storage kind and the optimization level make no difference to the bytes;
# 4. every script in tests/failing and tests/invalid fails, for the reason in its
#    description;
# 5. the fixtures haven't drifted from what the scripts produce now, and that check
#    notices drift;
# 6. detcheck itself notices a changed byte.

set -eu
cd "$(dirname "$0")"

OUT=out/check
RUN=zig-out/bin/run
DET=zig-out/bin/detcheck

rm -rf "$OUT"
mkdir -p "$OUT"

echo "== build (debug and release)"
zig build
zig build -Doptimize=ReleaseFast --prefix out/release
RELEASE_RUN=out/release/bin/run

echo "== determinism: each script run twice"
for script in scripts/*.json tests/valid/*.json; do
    name=$(basename "$script" .json)
    "$RUN" "$script" "$OUT/$name.a.db"
    "$RUN" "$script" "$OUT/$name.b.db"
    printf '%-24s ' "$name"
    "$DET" "$OUT/$name.a.db" "$OUT/$name.b.db"
done

echo "== storage kinds and optimization levels"
for script in scripts/*.json tests/valid/*.json; do
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

flip_byte() { # file, byte offset. flips every bit of that byte
    old=$(od -An -tu1 -j "$2" -N 1 "$1" | tr -d ' ')
    printf "$(printf '\\%03o' $((old ^ 255)))" | dd of="$1" bs=1 seek="$2" conv=notrunc 2> /dev/null
}

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
