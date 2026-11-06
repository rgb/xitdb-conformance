#!/bin/sh
# The gate for this repository. It stops at the first problem.
#
# 1. everything builds;
# 2. every script runs, twice, and the two files differ only in the commit ID and
#    checksum of each trailer (see src/detcheck.zig for exactly what's checked);
# 3. the storage kind and the optimization level make no difference to the bytes;
# 4. every script in tests/failing and tests/invalid fails, for the reason in its
#    description;
# 5. detcheck itself notices a changed byte.

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
    "$RUN" "$script" "$OUT/$name.memory.db" --kind memory
    "$RELEASE_RUN" "$script" "$OUT/$name.release.db"
    "$DET" "$OUT/$name.a.db" "$OUT/$name.file.db" > /dev/null
    "$DET" "$OUT/$name.a.db" "$OUT/$name.memory.db" > /dev/null
    "$DET" "$OUT/$name.a.db" "$OUT/$name.release.db" > /dev/null
    echo "$name: buffered_file == file == memory == release"
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

echo "== detcheck notices changes"
A="$OUT/01-list-root-hash-map.a.db"
B="$OUT/01-list-root-hash-map.b.db"
expect_detcheck_failure() { # byte offset, what's there, expected message
    corrupt="$OUT/corrupt.db"
    cp "$B" "$corrupt"
    cp "$B.sidecar.json" "$corrupt.sidecar.json"
    # flip every bit of that byte
    old=$(od -An -tu1 -j "$1" -N 1 "$B" | tr -d ' ')
    printf "$(printf '\\%03o' $((old ^ 255)))" | dd of="$corrupt" bs=1 seek="$1" conv=notrunc 2> /dev/null
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

echo "== all checks passed"
