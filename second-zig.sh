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
#
# With SECOND_ZIG_KEEP set to a folder, it also keeps there what each part wrote, and a line for
# each script saying how it went, which is what follow.sh compares from one commit to the next.

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

KEEP=${SECOND_ZIG_KEEP:-}
rm -rf "$WORK"
mkdir -p "$WORK/xitdb" "$REPO" "$WORK/runs"
if [ -n "$KEEP" ]; then
    rm -rf "$KEEP"
    mkdir -p "$KEEP/valid" "$KEEP/zig-only" "$KEEP/gen"
    : > "$KEEP/valid.txt"
    : > "$KEEP/zig-only.txt"
    : > "$KEEP/failing.txt"
    : > "$KEEP/differs.txt"
    : > "$KEEP/undefined.txt"
fi

# what follow.sh goes by, if it's keeping things: a line for the script, and its files
keep() { # list, name, outcome
    [ -n "$KEEP" ] || return 0
    echo "$2 $3" >> "$KEEP/$1.txt"
    for file in "$WORK/runs/$2".db "$WORK/runs/$2".*.db "$WORK/runs/$2".db.sidecar.json; do
        [ -e "$file" ] && cp "$file" "$KEEP/$1/"
    done
    return 0
}
git -C "$CHECKOUT" archive "$COMMIT" | tar -x -C "$WORK/xitdb"
git archive HEAD build.zig build.zig.zon src tests | tar -x -C "$REPO"

# an export has no repository for build.zig to ask, so it's given the commits it was exported from
if ! (cd "$REPO" && zig build -Dxitdb-commit="$COMMIT" -Dconformance-commit="$(git rev-parse HEAD)") > "$WORK/build.log" 2>&1; then
    echo "second-zig: the harness doesn't build against $SHORT:"
    head -n 20 "$WORK/build.log"
    exit 1
fi
BIN=$REPO/zig-out/bin

source_of() { # name of a fixture
    for dir in scripts tests/valid tests/generated tests/from-other-zig tests/port-variants; do
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
        "$BIN/run" "$script" "$WORK/runs/$name.db" --port || {
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
# original can't do and refuses, and that a corrected commit can. --port is what a fixture is for.
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
    if ! "$BIN/run" "$script" "$WORK/runs/$name.db" --allow-port-differences --port > /dev/null 2> "$WORK/runs/$name.err"; then
        failed=$((failed + 1))
        echo "fails: $name: $(head -n 1 "$WORK/runs/$name.err" | cut -c1-160)"
        keep valid "$name" "fails: $(head -n 1 "$WORK/runs/$name.err" | sed 's/, which started at.*//' | cut -c1-160)"
    elif "$BIN/detcheck" "$WORK/runs/$name.db" "$FIXTURES/valid/$name.db" > /dev/null 2> "$WORK/runs/$name.err"; then
        same=$((same + 1))
        keep valid "$name" passes
    else
        different=$((different + 1))
        echo "different: $name: $(head -n 1 "$WORK/runs/$name.err" | sed 's/^detcheck: FAILED: //' | cut -c1-120)"
        keep valid "$name" passes
    fi
    rm -f "$WORK/runs/$name".*
done
echo "$same with the same bytes, $different with different bytes, $failed that fail"
if [ "$skipped" -gt 0 ]; then
    echo "$skipped not compared, as their expected files are from another commit"
fi

echo
echo "== what's only for Zig"
# tests/zig-only.txt's scripts, as Zig runs them without --port
runs=0
fail_zig=0
while read -r name why; do
    case "$name" in
        "" | "#"*) continue ;;
    esac
    script=
    for dir in scripts tests/valid tests/generated; do
        if [ -f "$dir/$name.json" ]; then script=$dir/$name.json; fi
    done
    [ -n "$script" ] || continue
    if "$BIN/run" "$script" "$WORK/runs/$name.db" > /dev/null 2> "$WORK/runs/$name.err"; then
        runs=$((runs + 1))
        keep zig-only "$name" passes
    else
        fail_zig=$((fail_zig + 1))
        echo "fails: $name: $(head -n 1 "$WORK/runs/$name.err" | cut -c1-160)"
        keep zig-only "$name" "fails: $(head -n 1 "$WORK/runs/$name.err" | sed 's/, which started at.*//' | cut -c1-160)"
    fi
    rm -f "$WORK/runs/$name".*
done < tests/zig-only.txt
echo "$runs run on Zig, and $fail_zig fail"

echo
echo "== fixtures that should fail"
still=0
now_pass=0
for script in "$FIXTURES"/failing/*.json; do
    name=$(basename "$script" .json)
    code=0
    "$BIN/run" "$script" "$WORK/runs/failing.db" --allow-port-differences --port > /dev/null 2>&1 || code=$?
    if [ "$code" -eq 1 ]; then
        still=$((still + 1))
    else
        now_pass=$((now_pass + 1))
        echo "exit status $code: $name"
    fi
    [ -z "$KEEP" ] || echo "$name exit status $code" >> "$KEEP/failing.txt"
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
    [ -z "$KEEP" ] || echo "$name passes as the original: $zig_passes, and as the port: $port_passes" >> "$KEEP/differs.txt"
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
    [ -z "$KEEP" ] || echo "$kind $name exit status $code: $(grep -v '^$' "$WORK/runs/undefined.err" | head -n 1 | sed 's/^thread [0-9]* //' | cut -c1-110)" >> "$KEEP/undefined.txt"
    # a case with no text prints nothing to look for
    if [ "$code" -eq "$want" ] && { [ -z "$text" ] || grep -qF -- "$text" "$WORK/runs/undefined.err"; }; then
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
        safe-reads-*) "$BIN/gen" "${name#safe-reads-}" "$WORK/runs/gen.json" --reads --port-safe 2> /dev/null || true ;;
        safe-compact-*) "$BIN/gen" "${name#safe-compact-}" "$WORK/runs/gen.json" --compact --port-safe 2> /dev/null || true ;;
        safe-replica-*) "$BIN/gen" "${name#safe-replica-}" "$WORK/runs/gen.json" --replicate --port-safe 2> /dev/null || true ;;
        safe-*) "$BIN/gen" "${name#safe-}" "$WORK/runs/gen.json" --port-safe 2> /dev/null || true ;;
        gen-*) "$BIN/gen" "${name#gen-}" "$WORK/runs/gen.json" 2> /dev/null || true ;;
        reads-*) "$BIN/gen" "${name#reads-}" "$WORK/runs/gen.json" --reads 2> /dev/null || true ;;
        compact-*) "$BIN/gen" "${name#compact-}" "$WORK/runs/gen.json" --compact 2> /dev/null || true ;;
        replica-*) "$BIN/gen" "${name#replica-}" "$WORK/runs/gen.json" --replicate 2> /dev/null || true ;;
    esac
    [ -z "$KEEP" ] || cp "$WORK/runs/gen.json" "$KEEP/gen/$name.json"
    if cmp -s "$script" "$WORK/runs/gen.json"; then
        gen_same=$((gen_same + 1))
    else
        gen_different=$((gen_different + 1))
    fi
done
echo "$gen_same scripts the same, and $gen_different different"

rm -rf "$WORK/runs"
