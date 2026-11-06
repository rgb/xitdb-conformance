#!/bin/sh
# Runs this repository against another commit of the Zig implementation, and says what's different.
#
#   ./second-zig.sh <checkout> [commit]
#   ./second-zig.sh --regenerate <name>[,<name>...] <checkout> [commit]
#
# It exports that commit from the checkout, along with what's committed here, into a folder of
# its own under out/, and builds the harness there. So it changes nothing in either, and it
# doesn't matter what's uncommitted in them. The commit defaults to what the checkout has checked out.
#
# It prints how each fixture compares, whether each script that should fail does, which of the
# two things each behaviour in tests/port-differs does, what each case in tests/undefined does, and
# how many generated scripts gen would write differently. Differences are what it's for, so they
# don't make it fail. It only fails if it can't do this. README.md says what to do with what it says.
#
# --regenerate takes those fixtures' expected files from that commit, and records it in
# tests/zig-commits.txt. Commit that, and then run ./fixtures.sh for the manifest.

set -eu
cd "$(dirname "$0")"

REGENERATE=
if [ "${1:-}" = "--regenerate" ]; then
    REGENERATE=${2:?--regenerate needs names}
    shift 2
fi
CHECKOUT=${1:?usage: ./second-zig.sh [--regenerate <name>,...] <checkout> [commit]}
COMMIT=$(git -C "$CHECKOUT" rev-parse "${2:-HEAD}")
SHORT=$(printf '%s' "$COMMIT" | cut -c1-10)

HERE=$PWD
# check.sh points these at copies to show what this does without touching the real ones
FIXTURES=${FIXTURES:-fixtures}
OUT=${SECOND_ZIG_OUT:-out/second-zig}
WORK=$HERE/$OUT/$SHORT
REPO=$WORK/repo/conformance

rm -rf "$WORK"
mkdir -p "$WORK/xitdb" "$REPO" "$WORK/runs"
git -C "$CHECKOUT" archive "$COMMIT" | tar -x -C "$WORK/xitdb"
git archive HEAD build.zig build.zig.zon src tests | tar -x -C "$REPO"

if ! (cd "$REPO" && zig build) > "$WORK/build.log" 2>&1; then
    echo "second-zig: the harness doesn't build against $SHORT:"
    head -n 20 "$WORK/build.log"
    exit 1
fi
BIN=$REPO/zig-out/bin

source_of() { # name of a fixture
    for dir in scripts tests/valid tests/generated tests/from-other-zig; do
        if [ -f "$dir/$1.json" ]; then
            echo "$dir/$1.json"
            return 0
        fi
    done
    return 1
}

if [ -n "$REGENERATE" ]; then
    for name in $(printf '%s' "$REGENERATE" | tr ',' ' '); do
        script=$(source_of "$name") || {
            echo "second-zig: there's no script called $name"
            exit 1
        }
        "$BIN/run" "$script" "$WORK/runs/$name.db" || {
            echo "second-zig: $name doesn't pass on $SHORT, so it has no expected file to take"
            exit 1
        }
        cp "$WORK/runs/$name.db" "$WORK/runs/$name.db.sidecar.json" "$FIXTURES/valid/"
        for other in "$WORK/runs/$name".*.db; do
            [ -e "$other" ] || continue
            cp "$other" "$FIXTURES/valid/"
        done
        grep -v "^$name " tests/zig-commits.txt > "$WORK/commits" || true
        echo "$name $COMMIT" >> "$WORK/commits"
        cp "$WORK/commits" tests/zig-commits.txt
        echo "$name: its expected files are now from $SHORT"
    done
    echo "commit tests/zig-commits.txt, and then run ./fixtures.sh for the manifest"
    exit 0
fi

echo "Zig commit $COMMIT"
echo "the harness at $(git rev-parse --short=10 HEAD) of this repository"

echo
echo "== fixtures that should pass"
# what a script may use was decided by the original, and what's run here is what a commit does
# with it, so the guard is off. a stream of a sorted key with no position, say, is one that the
# original can't do and refuses, and that a corrected commit can.
same=0
different=0
failed=0
skipped=0
for script in "$FIXTURES"/valid/*.json; do
    case "$script" in *.sidecar.json) continue ;; esac
    name=$(basename "$script" .json)
    # an expected file from yet another commit has nothing to say about this one
    recorded=$(sed -n "s/^$name \([0-9a-f]*\)\$/\1/p" tests/zig-commits.txt)
    if [ -n "$recorded" ] && [ "$recorded" != "$COMMIT" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    if ! "$BIN/run" "$script" "$WORK/runs/$name.db" --allow-port-differences > /dev/null 2> "$WORK/runs/$name.err"; then
        failed=$((failed + 1))
        echo "fails: $name: $(head -n 1 "$WORK/runs/$name.err" | cut -c1-160)"
    elif "$BIN/detcheck" "$WORK/runs/$name.db" "$FIXTURES/valid/$name.db" > /dev/null 2> "$WORK/runs/$name.err"; then
        same=$((same + 1))
    else
        different=$((different + 1))
        echo "different: $name: $(head -n 1 "$WORK/runs/$name.err" | sed 's/^detcheck: FAILED: //' | cut -c1-120)"
    fi
    rm -f "$WORK/runs/$name".*
done
echo "$same with the same bytes, $different with different bytes, $failed that fail"
if [ "$skipped" -gt 0 ]; then
    echo "$skipped not compared, as their expected files are from another commit"
fi

echo
echo "== fixtures that should fail"
still=0
now_pass=0
for script in "$FIXTURES"/failing/*.json; do
    name=$(basename "$script" .json)
    code=0
    "$BIN/run" "$script" "$WORK/runs/failing.db" --allow-port-differences > /dev/null 2>&1 || code=$?
    if [ "$code" -eq 1 ]; then
        still=$((still + 1))
    else
        now_pass=$((now_pass + 1))
        echo "exit status $code: $name"
    fi
done
echo "$still still fail, and $now_pass don't"

echo
echo "== what the port corrects"
as_zig=0
as_port=0
for script in tests/port-differs/*.zig.json; do
    name=$(basename "$script" .zig.json)
    zig_passes=no
    port_passes=no
    "$BIN/run" "$script" "$WORK/runs/differs.db" --allow-port-differences > /dev/null 2>&1 && zig_passes=yes
    "$BIN/run" "tests/port-differs/$name.port.json" "$WORK/runs/differs.db" --allow-port-differences > /dev/null 2>&1 && port_passes=yes
    case "$zig_passes $port_passes" in
        "yes no")
            as_zig=$((as_zig + 1))
            echo "$name: as the original does"
            ;;
        "no yes")
            as_port=$((as_port + 1))
            echo "$name: as the port does"
            ;;
        *) echo "$name: passes as the original: $zig_passes, and as the port: $port_passes" ;;
    esac
done
echo "$as_zig as the original does, and $as_port as the port does"

echo
echo "== what tests/undefined shows"
unchanged=0
changed=0
while read -r kind name want text; do
    case "$kind" in
        script | wrapper) ;;
        *) continue ;;
    esac
    code=0
    if [ "$kind" = script ]; then
        "$BIN/run" "tests/undefined/$name.json" "$WORK/runs/undefined.db" > /dev/null 2> "$WORK/runs/undefined.err" || code=$?
    else
        "$BIN/undefined-wrappers" "$name" > /dev/null 2> "$WORK/runs/undefined.err" || code=$?
    fi
    if [ "$code" -eq "$want" ] && grep -qF -- "$text" "$WORK/runs/undefined.err"; then
        unchanged=$((unchanged + 1))
    else
        changed=$((changed + 1))
        echo "$kind $name: was exit status $want with \"$text\", and now it's $code: $(grep -v '^$' "$WORK/runs/undefined.err" | head -n 1 | cut -c1-110)"
    fi
done < tests/undefined/expected.txt
echo "$unchanged as they were, and $changed changed"

echo
echo "== what gen writes"
gen_same=0
gen_different=0
for script in tests/generated/*.json; do
    name=$(basename "$script" .json)
    case "$name" in
        gen-*) "$BIN/gen" "${name#gen-}" "$WORK/runs/gen.json" 2> /dev/null || true ;;
        reads-*) "$BIN/gen" "${name#reads-}" "$WORK/runs/gen.json" --reads 2> /dev/null || true ;;
        compact-*) "$BIN/gen" "${name#compact-}" "$WORK/runs/gen.json" --compact 2> /dev/null || true ;;
    esac
    if cmp -s "$script" "$WORK/runs/gen.json"; then
        gen_same=$((gen_same + 1))
    else
        gen_different=$((gen_different + 1))
    fi
done
echo "$gen_same scripts the same, and $gen_different different"

rm -rf "$WORK/runs"
