#!/bin/sh
# Runs two-processes.sh on Linux, so that the rule is held on Linux's files, maps and renames as well as macOS's.
# Zig here builds the writer and the original's reader for aarch64 Linux, and they run in a container, with this
# folder mounted read-only as /conformance, and the files written in the container's own /tmp unless --on-volume.
#
#   ./linux-two-processes.sh [--on-volume]
#
# Where the files lie can decide the test for a reader that maps the file only on a kind of volume it trusts, and reads
# by file calls elsewhere: on the container's overlay, the default, such a reader might never map. --on-volume puts them
# on a named volume of their own, which it makes and removes, as near to a Linux disk as a container has; a folder of
# the Mac's shared for writing would be further from one. Either way it prints the file system's kind.
#
# A port's reader for Linux is given by XITDB_READER, as a path inside the container, so one in this folder is under
# /conformance. The image is the one the port's gate uses, swift 6.4.2, by its digest, and it's never pulled: sh and
# perl are all the test needs, which any Debian or Ubuntu image has, but a port's reader built with Swift needs the
# Swift runtime, which this one has. TWO_PROCESSES_IMAGE names another. The container has no network.
#
# It exits with 77, and only then, when it didn't try: no docker here, or no such image here. Anything else that goes
# wrong, the build, the container, or a reader that breaks the rule, is a failure, and a 77 from inside the container
# is made one too, so that check.sh can go past a 77 and never past a failure.

set -eu
cd "$(dirname "$0")"

IMAGE=${TWO_PROCESSES_IMAGE:-swift@sha256:119ff7d833ea622851b459513333bb4bda5ebb32b7acd05dd05077d5b0383129}
TARGET=aarch64-linux-musl
PREFIX=out/linux
FILES=/tmp/two-processes
VOLUME=
case "${1:-}" in
    "") ;;
    --on-volume)
        VOLUME=xitdb-two-processes-$$
        FILES=/files/two-processes
        ;;
    *)
        echo "usage: ./linux-two-processes.sh [--on-volume]"
        exit 2
        ;;
esac

NOT_TRIED=77
command -v docker > /dev/null || {
    echo "no docker here, so the two processes weren't tried on Linux"
    exit $NOT_TRIED
}
docker image inspect "$IMAGE" > /dev/null 2>&1 || {
    echo "the image $IMAGE isn't here, and this never pulls it, so the two processes weren't tried on Linux"
    exit $NOT_TRIED
}

# static binaries, so they don't depend on the image's libc
zig build two-processes -Dtarget="$TARGET" -p "$PREFIX"

if [ -n "$VOLUME" ]; then
    docker volume create "$VOLUME" > /dev/null
    # the container's own removal can still hold it for a moment after it has exited
    trap 'for try in 1 2 3 4 5 6 7 8 9 10; do docker volume rm -f "$VOLUME" > /dev/null 2>&1 && break; sleep 0.5; done
        docker volume inspect "$VOLUME" > /dev/null 2>&1 && echo "the volume $VOLUME couldn'"'"'t be removed"' EXIT
fi

# a port's reader, if one is named, by its path inside the container
set -- -e TWO_PROCESSES_DRIVER=/conformance/$PREFIX/bin/two-processes -e TWO_PROCESSES_OWN_READER=/conformance/$PREFIX/bin/reader \
    -e TWO_PROCESSES_OUT="$FILES" -e TWO_PROCESSES_IMAGE="$IMAGE"
if [ -n "$VOLUME" ]; then set -- "$@" -v "$VOLUME:/files"; fi
if [ -n "${XITDB_READER:-}" ]; then set -- "$@" -e "XITDB_READER=$XITDB_READER"; fi

status=0
docker run --rm --pull never --network none -v "$PWD:/conformance:ro" "$@" "$IMAGE" \
    sh -c 'mkdir -p "$TWO_PROCESSES_OUT"
        echo "on $(uname -sm), in $TWO_PROCESSES_IMAGE, which is $(. /etc/os-release && echo "$PRETTY_NAME"), with $(perl -e "print \"perl \$^V\""), the files on $(stat -f -c %T "$TWO_PROCESSES_OUT") at $TWO_PROCESSES_OUT"
        sh /conformance/two-processes.sh' || status=$?
if [ "$status" -eq "$NOT_TRIED" ]; then
    echo "the container exited with $NOT_TRIED, which this gives only when it didn't try, so it's a failure"
    exit 1
fi
exit "$status"
