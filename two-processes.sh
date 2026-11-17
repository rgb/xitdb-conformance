#!/bin/sh
# Holds the arrangement a port's first client rests on. The original commits to a file while a reader in another
# process, with no lock and one database object, reads it, and every answer is one of the committed states, in order,
# up to the last. And a reader that kept the file open while a compacted copy was renamed over its name goes on seeing
# the old database, whole. SCRIPT-FORMAT.md section 15 says what a reader has to print.
#
#   ./two-processes.sh [reader]
#
# The original's own reader, zig-out/bin/reader, always runs, on each storage kind it says it has, which holds the
# test itself. A port's reader is given as the argument, or as XITDB_READER, and runs on each kind its --kinds prints.
# Without one, it says so. check.sh runs it.
#
# Each run of the writer, all three of a reader's runs on one kind, has TWO_PROCESSES_ALARM seconds, 300 unless it's
# set. If they run out, it says which reader on which kind gave no answer, and in which run, by the writer's words for
# it. Whenever the writer doesn't end well, whatever is left of the readers it started is ended, each having a process
# group of its own.

set -eu
cd "$(dirname "$0")"

DRIVER=$PWD/zig-out/bin/two-processes
OWN=$PWD/zig-out/bin/reader
WORK=${TWO_PROCESSES_OUT:-out/two-processes}
ALARM=${TWO_PROCESSES_ALARM:-300}
[ -x "$DRIVER" ] && [ -x "$OWN" ] || { echo "run zig build first"; exit 2; }
rm -rf "$WORK"
mkdir -p "$WORK"

try() { # a reader, what to call it
    kinds=$("$1" --kinds) || { echo "two-processes: $1 --kinds failed"; exit 1; }
    [ -n "$kinds" ] || { echo "two-processes: $1 --kinds named no storage kind"; exit 1; }
    for kind in $kinds; do
        folder="$WORK/$2-$kind"
        status=0
        # a reader that stops answering would otherwise hold the gate for ever
        perl -e 'alarm shift; exec @ARGV' "$ALARM" "$DRIVER" "$1" "$kind" "$folder" || status=$?
        [ "$status" -eq 0 ] && continue
        for pid in $(cat "$folder/readers" 2> /dev/null); do
            kill -9 -- "-$pid" 2> /dev/null || true
        done
        # the alarm is SIGALRM, 14
        if [ "$status" -eq 142 ]; then
            echo "two-processes: the $2 reader on $kind gave no answer for $ALARM s, in the run \"$(cat "$folder/run" 2> /dev/null)\""
        else
            echo "two-processes: the $2 reader on $kind didn't hold to the rule"
        fi
        exit 1
    done
}

try "$OWN" original
READER=${1:-${XITDB_READER:-}}
if [ -n "$READER" ]; then
    try "$READER" port
else
    echo "no port's reader given (XITDB_READER), so only the original's was tried"
fi
