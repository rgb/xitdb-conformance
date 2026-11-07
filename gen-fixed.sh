#!/bin/sh
# The generated scripts that are committed, and so are among the fixtures.
#
#   ./gen-fixed.sh           writes them to tests/generated
#   ./gen-fixed.sh --check   fails if gen no longer writes exactly what's there
#
# A change to gen changes the scripts it writes, and with them the fixtures. reads-<seed>
# has reads added, and the same writes as what the same seed gives without them.
# compact-<seed> ends with a compaction, whose target is an expected file too.
# replica-<seed> ends with a sync, whose replica is one. safe-<seed>, safe-reads-<seed>,
# safe-compact-<seed> and safe-replica-<seed> are the same seeds with --port-safe.

set -eu
cd "$(dirname "$0")"

GEN=zig-out/bin/gen
DIR=tests/generated
SEEDS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18"
READ_SEEDS="101 102 103 104 105 106 107 108 109 110 111 112"
COMPACT_SEEDS="201 202 203 204 205 206"
REPLICA_SEEDS="301 302 303 304 305 306"

case "${1:-}" in
    "")
        mkdir -p "$DIR"
        for seed in $SEEDS; do
            "$GEN" "$seed" "$DIR/gen-$seed.json"
        done
        for seed in $READ_SEEDS; do
            "$GEN" "$seed" "$DIR/reads-$seed.json" --reads
        done
        for seed in $COMPACT_SEEDS; do
            "$GEN" "$seed" "$DIR/compact-$seed.json" --compact
        done
        for seed in $REPLICA_SEEDS; do
            "$GEN" "$seed" "$DIR/replica-$seed.json" --replicate
        done
        for seed in $SEEDS; do
            "$GEN" "$seed" "$DIR/safe-$seed.json" --port-safe
        done
        for seed in $READ_SEEDS; do
            "$GEN" "$seed" "$DIR/safe-reads-$seed.json" --reads --port-safe
        done
        for seed in $COMPACT_SEEDS; do
            "$GEN" "$seed" "$DIR/safe-compact-$seed.json" --compact --port-safe
        done
        for seed in $REPLICA_SEEDS; do
            "$GEN" "$seed" "$DIR/safe-replica-$seed.json" --replicate --port-safe
        done
        echo "$DIR: wrote the scripts for seeds $SEEDS, with reads for $READ_SEEDS, with a compaction for $COMPACT_SEEDS, and with a replica for $REPLICA_SEEDS"
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
        for seed in $COMPACT_SEEDS; do
            "$GEN" "$seed" out/gen-check.json --compact
            cmp -s out/gen-check.json "$DIR/compact-$seed.json" || {
                echo "gen-fixed: seed $seed no longer gives $DIR/compact-$seed.json. Run ./gen-fixed.sh"
                exit 1
            }
            count=$((count + 1))
        done
        for seed in $REPLICA_SEEDS; do
            "$GEN" "$seed" out/gen-check.json --replicate
            cmp -s out/gen-check.json "$DIR/replica-$seed.json" || {
                echo "gen-fixed: seed $seed no longer gives $DIR/replica-$seed.json. Run ./gen-fixed.sh"
                exit 1
            }
            count=$((count + 1))
        done
        same_with_port_safe() { # seed, name, flags
            # shellcheck disable=SC2086
            "$GEN" "$1" out/gen-check.json $3 --port-safe
            cmp -s out/gen-check.json "$DIR/$2.json" || {
                echo "gen-fixed: seed $1 no longer gives $DIR/$2.json. Run ./gen-fixed.sh"
                exit 1
            }
            count=$((count + 1))
        }
        for seed in $SEEDS; do same_with_port_safe "$seed" "safe-$seed" ""; done
        for seed in $READ_SEEDS; do same_with_port_safe "$seed" "safe-reads-$seed" --reads; done
        for seed in $COMPACT_SEEDS; do same_with_port_safe "$seed" "safe-compact-$seed" --compact; done
        for seed in $REPLICA_SEEDS; do same_with_port_safe "$seed" "safe-replica-$seed" --replicate; done
        for script in "$DIR"/*.json; do
            name=$(basename "$script" .json)
            case "$name" in
                safe-reads-*) seed=${name#safe-reads-} seeds=$READ_SEEDS ;;
                safe-compact-*) seed=${name#safe-compact-} seeds=$COMPACT_SEEDS ;;
                safe-replica-*) seed=${name#safe-replica-} seeds=$REPLICA_SEEDS ;;
                safe-*) seed=${name#safe-} seeds=$SEEDS ;;
                gen-*) seed=${name#gen-} seeds=$SEEDS ;;
                reads-*) seed=${name#reads-} seeds=$READ_SEEDS ;;
                compact-*) seed=${name#compact-} seeds=$COMPACT_SEEDS ;;
                replica-*) seed=${name#replica-} seeds=$REPLICA_SEEDS ;;
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
