#!/bin/sh
# Runs fresh generated scripts through everything, for as long as you like. It isn't
# part of the gate, which only regenerates the committed ones.
#
#   ./gen-live.sh <how many> [first seed] [ops per script]
#
# Each script has reads in it and ends with a compaction and a sync, and must run on every storage kind
# it can run on, and the runs must differ only in commit IDs and checksums. The script the
# same seed gives with reads and no compaction must give the same file as the one with neither.
# A script that doesn't is kept in out/live, with the reason in <seed>.err, and it's a bug in
# gen, in run, or in the engine.
#
# With PORT_SAFE=yes it's gen --port-safe, and each script also has to run the same under
# run --port, and keep off everything run --note-port-changes notes, other than what stays
# valid on the port: an init through a cursor from before a freeze, a read through one, and a
# write that raises ExpectedTxStart.

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
DUMP=$BIN/dump
OUT=${OUT:-out/live}
GEN_FLAGS=
if [ "${PORT_SAFE:-}" = yes ]; then GEN_FLAGS=--port-safe; fi

mkdir -p "$OUT"
failed=0
seed=$FIRST
last=$((FIRST + COUNT))
while [ "$seed" -lt "$last" ]; do
    script="$OUT/$seed.json"
    db="$OUT/$seed.db"
    err="$OUT/$seed.err"
    ok=yes
    "$GEN" "$seed" "$script" --ops "$OPS" --reads --compact --replicate $GEN_FLAGS 2> "$err" || ok=no
    if [ "$ok" = yes ]; then "$RUN" "$script" "$db" 2>> "$err" || ok=no; fi
    # all of the file has to be readable, including what the script never reads back
    if [ "$ok" = yes ]; then "$DUMP" "$db" > /dev/null 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$DUMP" "$OUT/$seed.compacted.db" > /dev/null 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$DUMP" "$OUT/$seed.replica.db" > /dev/null 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$RUN" "$script" "$db.again" 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$DET" "$db" "$db.again" > /dev/null 2>> "$err" || ok=no; fi
    # reads change nothing
    if [ "$ok" = yes ]; then "$GEN" "$seed" "$db.plain.json" --ops "$OPS" $GEN_FLAGS 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$RUN" "$db.plain.json" "$db.plain" 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$GEN" "$seed" "$db.reads.json" --ops "$OPS" --reads $GEN_FLAGS 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$RUN" "$db.reads.json" "$db.reads" 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$DET" --ignore-reads "$db.reads" "$db.plain" > /dev/null 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$RUN" "$script" "$db.file" --kind file 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ]; then "$DET" "$db" "$db.file" > /dev/null 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ] && ! grep -q '"read_only":true' "$script"; then
        "$RUN" "$script" "$db.memory" --kind memory 2>> "$err" || ok=no
        if [ "$ok" = yes ]; then "$DET" "$db" "$db.memory" > /dev/null 2>> "$err" || ok=no; fi
    fi
    if [ "$ok" = yes ] && [ -n "$GEN_FLAGS" ]; then "$RUN" "$script" "$db.port" --port 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ] && [ -n "$GEN_FLAGS" ]; then "$DET" "$db" "$db.port" > /dev/null 2>> "$err" || ok=no; fi
    if [ "$ok" = yes ] && [ -n "$GEN_FLAGS" ]; then
        # the memory kind is the one that can tell what a failed op left behind
        kind=memory
        if grep -q '"read_only":true' "$script"; then kind=buffered_file; fi
        changes=$("$RUN" "$script" "$db.notes" --kind "$kind" --note-port-changes 2>&1 | grep '^change ' | grep -Ev '^change (18-init|18-reads|18-reads-earlier|1-raises) ' || true)
        if [ -n "$changes" ]; then
            echo "it does what the port changes: $(echo "$changes" | head -n 1)" >> "$err"
            ok=no
        fi
    fi
    if [ "$ok" = yes ]; then
        rm -f "$script" "$err"
    else
        failed=$((failed + 1))
        echo "seed $seed failed: $(head -n 1 "$err" | cut -c1-200)"
    fi
    rm -f "$db" "$db".* "$OUT/$seed".*.db
    seed=$((seed + 1))
done
echo "$COUNT scripts from seed $FIRST, $failed failed"
[ "$failed" -eq 0 ]
