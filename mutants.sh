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
# ones did. Fails if a mutant gets past all of them, or if only one script notices it, which is
# how easily a change to that script could leave it unnoticed. It isn't part of the gate, as it
# builds the runner once per mutant. "Noticed" covers a different file, a failed expectation,
# and a crash, and a mutant that only makes a script run forever counts too, after 30 seconds.

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
    OLD=$1 NEW=$2 WANT=$3 perl -0777 -pi -e '
        BEGIN { $old = $ENV{OLD}; $new = $ENV{NEW}; $want = $ENV{WANT}; $n = 0; }
        s/\Q$old\E/++$n == $want ? $new : $old/ge;
        END { die "patch: \"$old\" appears $n times\n" if $n < $want; }
    ' "$WORK/zig/src/lib.zig"
}

failed=0
thin=0
tried=0

try_mutant() { # name, old text, new text, which occurrence
    name=$1
    # MUTANTS_ONLY is for trying some of them, as a list of patterns for their names
    wanted=no
    set -f
    for pattern in ${MUTANTS_ONLY:-*}; do
        # shellcheck disable=SC2254
        case "$name" in
            $pattern) wanted=yes ;;
        esac
    done
    set +f
    if [ "$wanted" = no ]; then return 0; fi
    tried=$((tried + 1))
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
    if [ "$noticed" -eq 1 ]; then
        thin=$((thin + 1))
        echo "    only:$deep$others"
    fi
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
try_mutant compact-full-blocks-as-partial "if (@as(u128, size) == @as(u128, child_size) * SLOT_COUNT) {" "if (size != size) {"
try_mutant compact-keeps-what-is-past-the-end "if (remaining == 0) break;" "if (remaining == 0 and false) break;"
try_mutant compact-first-moment "if (try self.rootCursor().readPathSlot(void, &.{.{ .array_list_get = -1 }})) |last_moment| {" "if (try self.rootCursor().readPathSlot(void, &.{.{ .array_list_get = 0 }})) |last_moment| {"
try_mutant compact-history-whole "switch (source_root.tag) {" "switch (@as(Tag, if (source_root.tag == .array_list) .hash_map else source_root.tag)) {"
try_mutant compact-empty-root-commits "if (source_root.empty()) return target;" "if (source_root.empty() and false) return target;"
try_mutant compact-target-not-checked "if (!(try target.readRootSlot()).empty()) return error.TargetNotEmpty;" "if (!(try target.readRootSlot()).empty() and false) return error.TargetNotEmpty;"
try_mutant compact-hash-id-not-inherited "opts.hash_id = target_opts.hash_id orelse self.header.hash_id;" "opts.hash_id = target_opts.hash_id;"
try_mutant compact-hash-id-always-the-source-s "opts.hash_id = target_opts.hash_id orelse self.header.hash_id;" "opts.hash_id = self.header.hash_id;"
try_mutant compact-loses-format-tags "const format_tag_size: u64 = if (slot.full) 2 else 0;" "const format_tag_size: u64 = if (slot.full and false) 2 else 0;"
try_mutant compact-loses-full "return .{ .value = new_offset, .tag = slot.tag, .full = slot.full };" "return .{ .value = new_offset, .tag = slot.tag, .full = false };"
try_mutant compact-memory-offsets-not-cleared "offset_map.clearRetainingCapacity();" "// not cleared"
try_mutant compact-disk-offsets-not-cleared "try offset_map.reset();" "// not reset"
try_mutant compact-bytes-not-shared "if (try self.getOffset(slot.value)) |target_offset| {" "if (if (slot.value == slot.value) @as(?u64, null) else try self.getOffset(slot.value)) |target_offset| {"
try_mutant compact-objects-not-shared "if (try self.getOffset(source_offset)) |target_offset| {" "if (if (source_offset == source_offset) @as(?u64, null) else try self.getOffset(source_offset)) |target_offset| {"
# replication
try_mutant replica-always-replaced "return if (trailer.checksum == state.checksum) state.committed_size else 0;" "return if (trailer.checksum == state.checksum and false) state.committed_size else 0;"
try_mutant replica-never-replaced "return if (trailer.checksum == state.checksum) state.committed_size else 0;" "return if (trailer.checksum == state.checksum or true) state.committed_size else 0;"
try_mutant first-sync-keeps-latest-root-header ".file_size = end, .root = trailer.root" ".file_size = try self.committedSize(), .root = trailer.root"
try_mutant first-sync-keeps-latest-root-slot ".file_size = end, .root = trailer.root" ".file_size = end, .root = if (end == end) try self.readRootSlot() else trailer.root"
try_mutant replica-ahead-not-noticed "if (state.committed_size > try self.committedSize()) return 0;" "if (state.committed_size > try self.committedSize() and false) return 0;"
try_mutant read-past-committed-allowed "if (start > end or end > try self.committedSize()) return error.InvalidRange;" "if (start > end) return error.InvalidRange;"
try_mutant read-backwards-allowed "if (start > end or end > try self.committedSize()) return error.InvalidRange;" "if (end > try self.committedSize()) return error.InvalidRange;"
try_mutant read-inside-root-header-allowed "if (start > 0 and start < ROOT_HEADER_END) return error.InvalidRange;" "if (start > 0 and start < ROOT_HEADER_END and false) return error.InvalidRange;"
try_mutant apply-anywhere-allowed "} else return error.InvalidRange;

            var writer = self.core.writer();
            try writer.seekTo(start);
            try reader.streamExact64" "}

            var writer = self.core.writer();
            try writer.seekTo(start);
            try reader.streamExact64"
try_mutant apply-at-0-keeps-what-was-there "try self.core.setLength(0);" "_ = &self.core;"
try_mutant apply-keeps-leftovers "// discard anything past the committed bytes, such as the remains of an interrupted sync
                try self.truncate();" "// discard anything past the committed bytes, such as the remains of an interrupted sync"
try_mutant apply-at-0-keeps-the-old-header "try self.core.sync();
                self.header = try self.readAndValidateHeader();" "try self.core.sync();
                _ = try self.readAndValidateHeader();"
try_mutant apply-leaves-root-header "try self.core.sync();
                try self.writeRootHeader(trailer.root);" "try self.core.sync();
                _ = trailer;"
try_mutant trailer-checksum-not-checked "if (trailer.checksum != RootTrailer.computeChecksum(self.header.file_id, trailer_pos, trailer.root, trailer.commit_id)) return error.InvalidDatabase;" "if (trailer.checksum != RootTrailer.computeChecksum(self.header.file_id, trailer_pos, trailer.root, trailer.commit_id) and false) return error.InvalidDatabase;"

if [ "$tried" -eq 0 ]; then
    echo "MUTANTS_ONLY matched no mutants"
    exit 1
fi
if [ "$failed" -gt 0 ]; then
    echo "$failed mutants got past every script"
    exit 1
fi
if [ "$thin" -gt 0 ]; then
    echo "$thin mutants were noticed by only one script"
    exit 1
fi
echo "all $tried mutants were noticed by more than one script"
