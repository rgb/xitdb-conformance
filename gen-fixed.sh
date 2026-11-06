#!/bin/sh
# The generated scripts that are committed, and so are among the fixtures.
#
#   ./gen-fixed.sh           writes them to tests/generated
#   ./gen-fixed.sh --check   fails if gen no longer writes exactly what's there
#
# A change to gen changes the scripts it writes, and with them the fixtures. reads-<seed>
# has reads added, and the same writes as what the same seed gives without them.

set -eu
cd "$(dirname "$0")"

GEN=zig-out/bin/gen
DIR=tests/generated
SEEDS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18"
READ_SEEDS="101 102 103 104 105 106 107 108 109 110 111 112"

case "${1:-}" in
    "")
        mkdir -p "$DIR"
        for seed in $SEEDS; do
            "$GEN" "$seed" "$DIR/gen-$seed.json"
        done
        for seed in $READ_SEEDS; do
            "$GEN" "$seed" "$DIR/reads-$seed.json" --reads
        done
        echo "$DIR: wrote the scripts for seeds $SEEDS, and with reads for $READ_SEEDS"
        ;;
    --check)
        mkdir -p out
        count=0
        for seed in $SEEDS; do
            "$GEN" "$seed" out/gen-check.json
            cmp -s out/gen-check.json "$DIR/gen-$seed.json" || {
                echo "gen-fixed: seed $seed no longer gives $DIR/gen-$seed.json. Run ./gen-fixed.sh"
                exit 1
            }
            count=$((count + 1))
        done
        for seed in $READ_SEEDS; do
            "$GEN" "$seed" out/gen-check.json --reads
            cmp -s out/gen-check.json "$DIR/reads-$seed.json" || {
                echo "gen-fixed: seed $seed no longer gives $DIR/reads-$seed.json. Run ./gen-fixed.sh"
                exit 1
            }
            count=$((count + 1))
        done
        for script in "$DIR"/*.json; do
            name=$(basename "$script" .json)
            case "$name" in
                gen-*) seed=${name#gen-} seeds=$SEEDS ;;
                reads-*) seed=${name#reads-} seeds=$READ_SEEDS ;;
                *)
                    echo "gen-fixed: $script doesn't look like a generated script"
                    exit 1
                    ;;
            esac
            case " $seeds " in
                *" $seed "*) ;;
                *)
                    echo "gen-fixed: $script isn't in the list of seeds"
                    exit 1
                    ;;
            esac
        done
        echo "$DIR: gen still writes the same $count scripts"
        ;;
    *)
        echo "usage: ./gen-fixed.sh [--check]"
        exit 2
        ;;
esac
