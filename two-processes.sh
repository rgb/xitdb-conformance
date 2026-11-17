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

set -eu
cd "$(dirname "$0")"

DRIVER=$PWD/zig-out/bin/two-processes
OWN=$PWD/zig-out/bin/reader
WORK=${TWO_PROCESSES_OUT:-out/two-processes}
[ -x "$DRIVER" ] && [ -x "$OWN" ] || { echo "run zig build first"; exit 2; }
rm -rf "$WORK"
mkdir -p "$WORK"

try() { # a reader, what to call it
    kinds=$("$1" --kinds) || { echo "two-processes: $1 --kinds failed"; exit 1; }
    [ -n "$kinds" ] || { echo "two-processes: $1 --kinds named no storage kind"; exit 1; }
    for kind in $kinds; do
        # a reader that stops answering would otherwise hold the gate for ever
        perl -e 'alarm shift; exec @ARGV' 300 "$DRIVER" "$1" "$kind" "$WORK/$2-$kind" || {
            echo "two-processes: the $2 reader on $kind didn't hold to the rule"
            exit 1
        }
    done
}

try "$OWN" original
READER=${1:-${XITDB_READER:-}}
if [ -n "$READER" ]; then
    try "$READER" port
else
    echo "no port's reader given (XITDB_READER), so only the original's was tried"
fi
