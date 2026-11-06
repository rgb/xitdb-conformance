#!/bin/sh
# Shows that the scripts tell copying from rewriting in place, by getting it wrong on purpose.
#
#   ./mutants.sh [scratch folder]
#
# A transaction changes what it made itself in place, and copies what's older than its
# start or a freeze. Each mutant below is a copy of the Zig original, never the original
# itself, with one of the places that decides this made to always copy or never copy.
# Every script is run against it, and compared with what the unchanged engine writes.
#
# It prints one line per mutant: how many of the scripts noticed, and which of the deep-*
# ones did. Fails if a mutant gets past all of them. It isn't part of the gate, as it builds
# the runner once per mutant. "Noticed" covers a different file, a failed expectation, and a
# crash, and a mutant that only makes a script run forever counts too, after 30 seconds.

set -eu
cd "$(dirname "$0")"

WORK=${1:-out/mutants}
ZIG_ORIGINAL=${ZIG_ORIGINAL:-../../xitdb}
HERE=$PWD
DET=$HERE/zig-out/bin/detcheck
RUN=$HERE/zig-out/bin/run

[ -x "$RUN" ] && [ -x "$DET" ] || { echo "run zig build first"; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/reference" "$WORK/zig"
git -C "$ZIG_ORIGINAL" archive HEAD src | tar -x -C "$WORK/zig"
cp "$WORK/zig/src/lib.zig" "$WORK/lib.original.zig"

SCRIPTS=$(ls scripts/*.json tests/valid/*.json tests/generated/*.json)

for script in $SCRIPTS; do
    name=$(basename "$script" .json)
    "$RUN" "$script" "$WORK/reference/$name.db"
done

# replaces the given occurrence of some text, and fails if it isn't there
patch_lib() { # old text, new text, which occurrence
    OLD=$1 NEW=$2 WANT=$3 perl -pi -e '
        BEGIN { $old = $ENV{OLD}; $new = $ENV{NEW}; $want = $ENV{WANT}; $n = 0; }
        s/\Q$old\E/++$n == $want ? $new : $old/ge;
        END { die "patch: \"$old\" appears $n times\n" if $n < $want; }
    ' "$WORK/zig/src/lib.zig"
}

failed=0

try_mutant() { # name, old text, new text, which occurrence
    name=$1
    cp "$WORK/lib.original.zig" "$WORK/zig/src/lib.zig"
    patch_lib "$2" "$3" "${4:-1}"
    if cmp -s "$WORK/lib.original.zig" "$WORK/zig/src/lib.zig"; then
        echo "$name: the patch changed nothing"
        exit 1
    fi
    zig build-exe --dep xitdb -Mroot=src/run.zig "-Mxitdb=$WORK/zig/src/lib.zig" "-femit-bin=$WORK/run-mutant" --cache-dir "$WORK/cache" 2> "$WORK/build.err" || {
        echo "$name: it doesn't build:"
        head -n 5 "$WORK/build.err"
        exit 1
    }
    noticed=0
    total=0
    deep=""
    others=""
    for script in $SCRIPTS; do
        script_name=$(basename "$script" .json)
        total=$((total + 1))
        same=yes
        perl -e 'alarm shift; exec @ARGV' 30 "$WORK/run-mutant" "$script" "$WORK/m.db" > /dev/null 2>&1 || same=no
        if [ "$same" = yes ]; then
            "$DET" "$WORK/reference/$script_name.db" "$WORK/m.db" > /dev/null 2>&1 || same=no
        fi
        if [ "$same" = no ]; then
            noticed=$((noticed + 1))
            case "$script_name" in
                deep-*) deep="$deep ${script_name#deep-}" ;;
                *) others="$others $script_name" ;;
            esac
        fi
    done
    printf '%-34s %3d of %d noticed; deep:%s\n' "$name" "$noticed" "$total" "${deep:- none}"
    if [ -n "${MUTANTS_VERBOSE:-}" ]; then
        echo "    others:$others"
    fi
    if [ "$noticed" -eq 0 ]; then failed=$((failed + 1)); fi
    rm -f "$WORK"/m.*
}

# the index blocks of array lists and hash maps
try_mutant index-block-always-copied "if (!try self.isOld(ptr, frozen_at)) return ptr;" "if (!(try self.isOld(ptr, frozen_at) or true)) return ptr;"
try_mutant index-block-never-copied "if (!try self.isOld(ptr, frozen_at)) return ptr;" "if (try self.isOld(ptr, frozen_at) or true) return ptr;"
# the header of an array list
try_mutant array-header-always-copied "if (try self.isOld(array_list_start, frozen_at)) {" "if (try self.isOld(array_list_start, frozen_at) or true) {"
try_mutant array-header-never-copied "if (try self.isOld(array_list_start, frozen_at)) {" "if (try self.isOld(array_list_start, frozen_at) and false) {"
# the header of a linked array list
try_mutant linked-header-always-copied "if (try self.isOld(header_ptr, frozen_at)) {" "if (try self.isOld(header_ptr, frozen_at) or true) {" 1
try_mutant linked-header-never-copied "if (try self.isOld(header_ptr, frozen_at)) {" "if (try self.isOld(header_ptr, frozen_at) and false) {" 1
# the first block of a hash map
try_mutant map-block-always-copied "if (try self.isOld(map_start, frozen_at)) {" "if (try self.isOld(map_start, frozen_at) or true) {"
try_mutant map-block-never-copied "if (try self.isOld(map_start, frozen_at)) {" "if (try self.isOld(map_start, frozen_at) and false) {"
# the header of a sorted map
try_mutant sorted-header-always-copied "if (try self.isOld(header_ptr, frozen_at)) {" "if (try self.isOld(header_ptr, frozen_at) or true) {" 2
try_mutant sorted-header-never-copied "if (try self.isOld(header_ptr, frozen_at)) {" "if (try self.isOld(header_ptr, frozen_at) and false) {" 2
# a hash map's key-value pairs
try_mutant kv-pair-always-copied "if (try self.isOld(ptr, frozen_at)) {" "if (try self.isOld(ptr, frozen_at) or true) {"
try_mutant kv-pair-never-copied "if (try self.isOld(ptr, frozen_at)) {" "if (try self.isOld(ptr, frozen_at) and false) {"
# the nodes of both kinds of tree
try_mutant tree-node-always-copied "return !old;" "return !old and false;"
try_mutant tree-node-never-copied "return !old;" "return !old or true;"
# everything at once, and the two things it goes by
try_mutant is-old-always "return ptr < @max(tx_start, frozen_at);" "return ptr < @max(tx_start, frozen_at) or true;"
try_mutant is-old-never "return ptr < @max(tx_start, frozen_at);" "return ptr < @max(tx_start, frozen_at) and false;"
try_mutant is-old-ignores-freeze-points "return ptr < @max(tx_start, frozen_at);" "_ = frozen_at; return ptr < tx_start;"
try_mutant is-old-ignores-transaction-start "return ptr < @max(tx_start, frozen_at);" "_ = tx_start; return ptr < frozen_at;"
try_mutant is-old-off-by-one "return ptr < @max(tx_start, frozen_at);" "return ptr <= @max(tx_start, frozen_at);"

# compaction, whose results should show in the target's bytes
try_mutant compact-partial-blocks-as-full "if (@as(u128, size) == @as(u128, child_size) * SLOT_COUNT) {" "if (size == size) {"
try_mutant compact-bytes-not-shared "if (try self.getOffset(slot.value)) |target_offset| {" "if (if (slot.value == slot.value) @as(?u64, null) else try self.getOffset(slot.value)) |target_offset| {"
try_mutant compact-objects-not-shared "if (try self.getOffset(source_offset)) |target_offset| {" "if (if (source_offset == source_offset) @as(?u64, null) else try self.getOffset(source_offset)) |target_offset| {"
# replication
try_mutant replica-always-replaced "return if (trailer.checksum == state.checksum) state.committed_size else 0;" "return if (trailer.checksum == state.checksum and false) state.committed_size else 0;"
try_mutant replica-never-replaced "return if (trailer.checksum == state.checksum) state.committed_size else 0;" "return if (trailer.checksum == state.checksum or true) state.committed_size else 0;"
try_mutant first-sync-keeps-latest-root-header ".file_size = end, .root = trailer.root" ".file_size = try self.committedSize(), .root = trailer.root"

if [ "$failed" -gt 0 ]; then
    echo "$failed mutants got past every script"
    exit 1
fi
echo "every mutant was noticed"
