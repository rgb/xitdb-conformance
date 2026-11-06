#!/bin/sh
# Runs fresh generated scripts through everything, for as long as you like. It isn't
# part of the gate, which only regenerates the committed ones.
#
#   ./gen-live.sh <how many> [first seed] [ops per script]
#
# Each script must run on every storage kind it can run on, and the runs must differ
# only in commit IDs and checksums. A script that doesn't is kept in out/live, with the
# reason in <seed>.err, and it's a bug in gen, in run, or in the engine.

set -eu
cd "$(dirname "$0")"

COUNT=${1:?usage: ./gen-live.sh <how many> [first seed] [ops per script]}
FIRST=${2:-1000000}
OPS=${3:-25}
# BIN and OUT are there so that a long run can use a copy, and survive a rebuild
BIN=${BIN:-zig-out/bin}
GEN=$BIN/gen
RUN=$BIN/run
DET=$BIN/detcheck
OUT=${OUT:-out/live}

mkdir -p "$OUT"
failed=0
seed=$FIRST
last=$((FIRST + COUNT))
while [ "$seed" -lt "$last" ]; do
    script="$OUT/$seed.json"
    db="$OUT/$seed.db"
    err="$OUT/$seed.err"
    ok=yes
    "$GEN" "$seed" "$script" --ops "$OPS" 2> "$err" || ok=no
    if [ "$ok" = yes ]; then "$RUN" "$script" "$db" 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$RUN" "$script" "$db.again" 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$DET" "$db" "$db.again" > /dev/null 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$RUN" "$script" "$db.file" --kind file 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$DET" "$db" "$db.file" > /dev/null 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ] && ! grep -q '"read_only":true' "$script"; then
        "$RUN" "$script" "$db.memory" --kind memory 2>> "$err" || ok=no
        if [ "$ok" = yes ]; then "$DET" "$db" "$db.memory" > /dev/null 2>> "$err" || ok=no; fi
    fi
    if [ "$ok" = yes ]; then
        rm -f "$script" "$err"
    else
        failed=$((failed + 1))
        echo "seed $seed failed: $(head -n 1 "$err" | cut -c1-200)"
    fi
    rm -f "$db" "$db".*
    seed=$((seed + 1))
done
echo "$COUNT scripts from seed $FIRST, $failed failed"
[ "$failed" -eq 0 ]
