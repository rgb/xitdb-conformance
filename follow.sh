#!/bin/sh
# Says what moves when the original goes from the commit the fixtures follow to a later one,
# commit by commit, and lists every place in this repository that names the commit followed.
#
#   ./follow.sh <checkout> [commit]
#
# The commit defaults to what the checkout has checked out. It runs second-zig.sh against the
# commit the manifest names and against each commit after it, up to that one, on the first-parent
# line, and keeps what each run wrote. FOLLOW_FROM starts it from another commit than the manifest's,
# which is how to see again what a pin that's already moved moved: FOLLOW_FROM=6b93af1 and 89da8e7
# are the commits conformance-09 followed. Then, for each commit, it compares with the one before:
#
# - which fixtures' files move, and which change their outcome, with the first line of why;
# - the same for the scripts that are only for Zig, run without --port;
# - which failing and invalid scripts no longer fail as they should, and which of the two things
#   each behaviour in tests/port-differs does;
# - what changes in tests/undefined, and which seeds gen writes differently.
#
# A file that moves is compared with detcheck, which reads either version, so the reason is its
# first difference. Nothing in either repository changes. Differences are what it's for, so they
# don't make it fail. README.md says what to do with what it says.

set -eu
cd "$(dirname "$0")"

CHECKOUT=${1:?usage: ./follow.sh <checkout> [commit]}
TARGET=$(git -C "$CHECKOUT" rev-parse "${2:-HEAD}")
PIN=$(sed -n 's/^  "zig_commit": "\([0-9a-f]*\)",$/\1/p' fixtures/manifest.json)
FROM=$(git -C "$CHECKOUT" rev-parse "${FOLLOW_FROM:-$PIN}")
[ -n "$PIN" ] || {
    echo "follow: fixtures/manifest.json doesn't say which commit the fixtures follow"
    exit 1
}
git -C "$CHECKOUT" merge-base --is-ancestor "$FROM" "$TARGET" || {
    echo "follow: $TARGET doesn't come after $FROM"
    exit 1
}
DET=$PWD/zig-out/bin/detcheck
[ -x "$DET" ] || {
    echo "follow: run zig build first"
    exit 2
}

OUT=${FOLLOW_OUT:-out/follow}
rm -rf "$OUT"
mkdir -p "$OUT"

# the commits in order, the one it starts from first
COMMITS="$FROM $(git -C "$CHECKOUT" rev-list --reverse --first-parent "$FROM..$TARGET")"
step=0
for commit in $COMMITS; do
    dir="$OUT/$step"
    SECOND_ZIG_KEEP="$dir" SECOND_ZIG_OUT="$OUT/build" ./second-zig.sh "$CHECKOUT" "$commit" > "$OUT/$step.report" 2>&1 || {
        echo "follow: second-zig.sh couldn't run against $commit:"
        tail -n 5 "$OUT/$step.report"
        exit 1
    }
    echo "$commit" > "$dir/commit"
    step=$((step + 1))
done
last=$((step - 1))

# `name passes` or `name fails <why>`, one per line, in each kept folder
status_of() { # folder, list, name
    sed -n "s/^$3 //p" "$1/$2.txt"
}

compare() { # what it's about, list, earlier folder, later folder
    moved=""
    changed=0
    same=0
    while read -r name outcome; do
        # the shell has no local variables, so this mustn't be called what the loop below uses
        was=$(status_of "$3" "$2" "$name")
        if [ "$was" != "$outcome" ]; then
            changed=$((changed + 1))
            echo "  $name: was \"${was:-not run}\", and now it's \"$outcome\""
            continue
        fi
        [ "$outcome" = passes ] || continue
        [ -f "$3/$2/$name.db" ] || continue
        if "$DET" "$3/$2/$name.db" "$4/$2/$name.db" > /dev/null 2> "$OUT/det.err"; then
            same=$((same + 1))
        else
            moved="$moved $name"
            echo "  $name moves: $(head -n 1 "$OUT/det.err" | sed 's/^detcheck: FAILED: //' | cut -c1-140)"
        fi
    done < "$4/$2.txt"
    count=$(printf '%s' "$moved" | wc -w | tr -d ' ')
    echo "$1: $same the same, $count moving, $changed changing their outcome"
}

compare_lines() { # what it's about, file name, earlier folder, later folder
    if cmp -s "$3/$2" "$4/$2"; then
        echo "$1: as before"
    else
        echo "$1:"
        diff "$3/$2" "$4/$2" | sed -n 's/^> /  now: /p; s/^< /  was: /p'
    fi
}

step=1
while [ "$step" -le "$last" ]; do
    before="$OUT/$((step - 1))"
    after="$OUT/$step"
    commit=$(cat "$after/commit")
    echo
    echo "== $(git -C "$CHECKOUT" log -1 --format='%h %s' "$commit")"
    compare "fixtures" valid "$before" "$after"
    compare "scripts only for Zig" zig-only "$before" "$after"
    compare_lines "failing scripts" failing.txt "$before" "$after"
    compare_lines "what the port corrects" differs.txt "$before" "$after"
    compare_lines "tests/undefined" undefined.txt "$before" "$after"
    gen=""
    for script in "$after"/gen/*.json; do
        name=$(basename "$script")
        cmp -s "$script" "$before/gen/$name" || gen="$gen ${name%.json}"
    done
    echo "gen: $(printf '%s' "$gen" | wc -w | tr -d ' ') seeds written differently${gen:+:$gen}"
    step=$((step + 1))
done

echo
echo "== the places that name $(printf '%s' "$PIN" | cut -c1-7), the commit followed"
short=$(printf '%s' "$PIN" | cut -c1-7)
git grep -c -e "$short" -- . ':!fixtures/valid/*.db' | sed 's/^/  /'
echo "Move the ones about the commit the fixtures follow, and leave the ones about what was so at it."
