#!/bin/sh
# Says how the commit the fixtures follow stands against upstream's HEAD. It never fails.
#
#   ./upstream.sh
#
# The pin is the manifest's zig_commit. Upstream's HEAD comes from `git ls-remote`, which reads one ref, fetches
# nothing and changes no checkout. tests/upstream.txt is the record, kept by hand, of each time someone held the pin
# against upstream's HEAD and what was decided, and its last line is what this compares with. Whatever it finds, it
# exits with 0: a pin behind upstream is a fact to act on with ./follow.sh, not a broken gate.
#
# XITDB_OFFLINE=1 skips the request and says so, for a run that mustn't use the network. Without a network the
# request gives up after about ten seconds. check.sh points XITDB_UPSTREAM and XITDB_UPSTREAM_RECORD at its own, to
# show each answer without the network.

cd "$(dirname "$0")" || exit 0

URL=${XITDB_UPSTREAM:-https://github.com/xit-vcs/xitdb.git}
RECORD=${XITDB_UPSTREAM_RECORD:-tests/upstream.txt}
LOCAL=../../xitdb

pin=$(sed -n 's/^  "zig_commit": "\([0-9a-f]*\)",$/\1/p' fixtures/manifest.json)
last=$(grep -v '^#' "$RECORD" 2> /dev/null | grep . | tail -n 1)
last_date=$(echo "$last" | awk '{ print $1 }')
last_head=$(echo "$last" | awk '{ print $2 }')
short() { echo "$1" | cut -c1-7; }

if [ -n "${XITDB_OFFLINE:-}" ]; then
    echo "upstream wasn't asked (XITDB_OFFLINE), so the pin $(short "$pin") wasn't held against its HEAD; it last was on $last_date"
    exit 0
fi

answer=$(mktemp) || exit 0
GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=10 git ls-remote "$URL" HEAD > "$answer" 2> /dev/null &
asking=$!
tenths=0
while kill -0 "$asking" 2> /dev/null && [ "$tenths" -lt 100 ]; do
    sleep 0.1
    tenths=$((tenths + 1))
done
kill "$asking" 2> /dev/null
wait "$asking" 2> /dev/null
head=$(awk '$2 == "HEAD" { print $1 }' "$answer")
rm -f "$answer"

if [ -z "$head" ]; then
    echo "upstream couldn't be reached, so the pin $(short "$pin") wasn't held against its HEAD; it last was on $last_date"
    exit 0
fi
if [ "$head" = "$pin" ]; then
    echo "the pin is upstream's HEAD, $(short "$pin")"
    exit 0
fi

# how far past the pin, if the original's checkout here has upstream's HEAD
past="past the pin $(short "$pin")"
if git -C "$LOCAL" cat-file -e "$head^{commit}" 2> /dev/null && git -C "$LOCAL" merge-base --is-ancestor "$pin" "$head" 2> /dev/null; then
    past="$(git -C "$LOCAL" rev-list --count "$pin..$head") commits past the pin $(short "$pin")"
fi
if [ "$head" = "$last_head" ]; then
    echo "upstream's HEAD is $(short "$head"), $past, known since $last_date ($RECORD)"
else
    echo "upstream's HEAD is $(short "$head"), $past, and not in $RECORD: ./follow.sh $LOCAL $head says what moves, once $LOCAL has it"
fi
exit 0
