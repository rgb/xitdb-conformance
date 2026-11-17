#!/bin/sh
# Shows that the fixtures notice when one of the port's guards goes wrong, by getting it wrong on purpose.
#
#   ./guard-mutants.sh [checkout of a later Zig] [scratch folder]
#
# The guards are what `run --port` acts out, as SCRIPT-FORMAT.md section 11 says. Each mutant below is a
# copy of src/run.zig with one of them made to let something through, to refuse something it shouldn't,
# or to recover to the wrong place, never the runner itself. It's built against the Zig each fixture
# comes from, and every fixture in fixtures/ is run with it under --port, as the port would run it.
# "Noticed" is a fixture that should pass failing, giving other bytes than its expected file, or going on
# for 30 seconds, and one that should fail passing or failing with another message.
#
# It prints one line per mutant, with how many fixtures noticed and, when that's only a few, which. Fails
# if a mutant gets past all of them, or if only one notices it. mutants.sh does the same for the engine,
# on the scripts as Zig runs them. This isn't part of the gate either, as it builds the runner twice for
# each mutant.
#
# The fixtures from another Zig commit, which tests/zig-commits.txt names, need a checkout that has that
# commit, as for second-zig.sh. Without one, they're left out, and it says so.

set -eu
cd "$(dirname "$0")"

OTHER=${1:-}
WORK=${2:-out/guard-mutants}
DET=$PWD/zig-out/bin/detcheck
ZIG_ORIGINAL=../../xitdb
[ -x "$DET" ] || { echo "run zig build first"; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/ref"
cp src/run.zig "$WORK/run.original.zig"

# a line for each fixture: its name, whether it should pass, its script, and the Zig it's from
python3 -I - fixtures/manifest.json > "$WORK/fixtures.txt" <<'EOF'
import json, sys
for f in json.load(open(sys.argv[1]))["fixtures"]:
    print(f["name"], f["outcome"], f["script"], f["zig_commit"])
EOF

# what run --version says a runner here was built from: that Zig commit, and run.zig as this changes it
build_options() { # the Zig commit
    printf 'pub const xitdb_commit = "%s";\npub const conformance_commit = "%s (src/run.zig as guard-mutants.sh changes it)";\n' \
        "$1" "$(git rev-parse HEAD)" > "$WORK/zig-$1/build_options.zig"
}

# the Zig of each commit the fixtures come from
ORIGINAL_COMMIT=$(git -C "$ZIG_ORIGINAL" rev-parse HEAD)
COMMITS=$(awk '{ print $4 }' "$WORK/fixtures.txt" | sort -u)
for commit in $COMMITS; do
    mkdir -p "$WORK/zig-$commit"
    if [ "$commit" = "$ORIGINAL_COMMIT" ]; then
        git -C "$ZIG_ORIGINAL" archive HEAD src | tar -x -C "$WORK/zig-$commit"
        build_options "$commit"
    elif [ -n "$OTHER" ] && git -C "$OTHER" cat-file -e "$commit^{commit}" 2> /dev/null; then
        git -C "$OTHER" archive "$commit" src | tar -x -C "$WORK/zig-$commit"
        build_options "$commit"
    else
        rmdir "$WORK/zig-$commit"
        left_out=$(awk -v c="$commit" '$4 == c' "$WORK/fixtures.txt" | wc -l | tr -d ' ')
        echo "the $left_out fixtures from Zig commit $commit are left out, as there's no checkout with it"
    fi
done

build() { # the runner's source, what to call it
    for commit in $COMMITS; do
        [ -d "$WORK/zig-$commit" ] || continue
        zig build-exe --dep xitdb --dep build_options "-Mroot=$1" "-Mxitdb=$WORK/zig-$commit/src/lib.zig" "-Mbuild_options=$WORK/zig-$commit/build_options.zig" \
            "-femit-bin=$WORK/$2-$commit" --cache-dir "$WORK/cache" 2> "$WORK/build.err" || return 1
    done
}

# how a fixture comes out with a runner: "ok", or how it failed
outcome() { # runner, name, outcome, script
    status=0
    perl -e 'alarm shift; exec @ARGV' 30 "$1" "fixtures/$4" "$WORK/m.db" --port > /dev/null 2> "$WORK/m.err" || status=$?
    if [ "$3" = pass ]; then
        if [ "$status" -ne 0 ]; then
            echo "failed with $status"
        elif "$DET" "fixtures/${4%.json}.db" "$WORK/m.db" > /dev/null 2>&1; then
            echo ok
        else
            echo "other bytes"
        fi
    else
        echo "$status $(head -n 1 "$WORK/m.err")"
    fi
    rm -f "$WORK"/m.*
}

# the runner as it is has to give every fixture as it's expected, or nothing here means anything
build src/run.zig run-reference || { echo "the runner doesn't build:"; head -n 5 "$WORK/build.err"; exit 1; }
fixtures=0
while read -r name want script commit; do
    [ -d "$WORK/zig-$commit" ] || continue
    got=$(outcome "$WORK/run-reference-$commit" "$name" "$want" "$script")
    if [ "$want" = pass ] && [ "$got" != ok ]; then
        echo "$name: the runner as it is gives \"$got\", so the fixtures aren't what it does"
        exit 1
    fi
    echo "$got" > "$WORK/ref/$name"
    fixtures=$((fixtures + 1))
done < "$WORK/fixtures.txt"
echo "$fixtures fixtures, each as it's expected with the runner as it is"

failed=0
thin=0
tried=0
wanted=no
mutant=

begin_mutant() { # name
    mutant=$1
    # MUTANTS_ONLY is for trying some of them, as a list of patterns for their names
    wanted=no
    set -f
    for pattern in ${MUTANTS_ONLY:-*}; do
        # shellcheck disable=SC2254
        case "$mutant" in
            $pattern) wanted=yes ;;
        esac
    done
    set +f
    cp "$WORK/run.original.zig" "$WORK/src/run.zig"
}

# replaces the given occurrence of some text, and fails if it isn't there
patch_run() { # old text, new text, which occurrence
    [ "$wanted" = yes ] || return 0
    OLD=$1 NEW=$2 WANT=${3:-1} perl -0777 -pi -e '
        BEGIN { $old = $ENV{OLD}; $new = $ENV{NEW}; $want = $ENV{WANT}; $n = 0; }
        s/\Q$old\E/++$n == $want ? $new : $old/ge;
        END { die "patch: \"$old\" appears $n times\n" if $n < $want; }
    ' "$WORK/src/run.zig"
}

end_mutant() {
    [ "$wanted" = yes ] || return 0
    tried=$((tried + 1))
    if cmp -s "$WORK/run.original.zig" "$WORK/src/run.zig"; then
        echo "$mutant: the patch changed nothing"
        exit 1
    fi
    build "$WORK/src/run.zig" run-mutant || {
        echo "$mutant: it doesn't build:"
        head -n 5 "$WORK/build.err"
        exit 1
    }
    noticed=0
    by=""
    while read -r name want script commit; do
        [ -d "$WORK/zig-$commit" ] || continue
        got=$(outcome "$WORK/run-mutant-$commit" "$name" "$want" "$script")
        if [ "$got" != "$(cat "$WORK/ref/$name")" ]; then
            noticed=$((noticed + 1))
            by="$by $name"
        fi
    done < "$WORK/fixtures.txt"
    printf '%-40s %3d of %d noticed\n' "$mutant" "$noticed" "$fixtures"
    if [ "$noticed" -le 4 ] || [ -n "${MUTANTS_VERBOSE:-}" ]; then
        echo "    by:${by:- none}"
    fi
    if [ "$noticed" -eq 0 ]; then failed=$((failed + 1)); fi
    if [ "$noticed" -eq 1 ]; then thin=$((thin + 1)); fi
}

# a write through a cursor from before the last freeze in this transaction (D24, row 6)
begin_mutant pre-freeze-write-allowed
patch_run "if (e.freezes < store.freezes and !(self.atBody(c) and goesOnAfterFreeze(kind_of_op, path))) return error.StaleCursor;" \
    "if (false and e.freezes < store.freezes and !(self.atBody(c) and goesOnAfterFreeze(kind_of_op, path))) return error.StaleCursor;"
end_mutant

# an init or a write through the transaction's body, which is the way to go on after a freeze, refused,
# and an init through any other cursor from before it let through, as D22 item 1 had it before D24
begin_mutant pre-freeze-init-through-body-refused
patch_run "if (e.freezes < store.freezes and !(self.atBody(c) and goesOnAfterFreeze(kind_of_op, path))) return error.StaleCursor;" \
    "if (e.freezes < store.freezes) return error.StaleCursor;"
end_mutant

begin_mutant pre-freeze-init-through-held-allowed
patch_run "if (e.freezes < store.freezes and !(self.atBody(c) and goesOnAfterFreeze(kind_of_op, path))) return error.StaleCursor;" \
    "if (e.freezes < store.freezes and !beginsWithInit(path) and !(self.atBody(c) and goesOnAfterFreeze(kind_of_op, path))) return error.StaleCursor;"
end_mutant

# no cursor is at the body's slot, so there's no way on after a freeze
begin_mutant body-cursor-not-exempt
patch_run "return cursor.db == self.body_db.? and cursor.slot_ptr.position == position;" \
    "return false and cursor.db == self.body_db.? and cursor.slot_ptr.position == position;"
end_mutant

# going on at the body's slot by writing first (D24 item 3) refused, all of it and each way of doing it:
# a path whose first part is a write, `write`, and `write_if_empty`
begin_mutant body-write-first-refused
patch_run "                .write, .write_if_empty => true,
                .write_path => beginsWithInit(path) or beginsWithWrite(path)," \
    "                .write, .write_if_empty => false,
                .write_path => beginsWithInit(path),"
end_mutant

begin_mutant body-write-path-refused
patch_run ".write_path => beginsWithInit(path) or beginsWithWrite(path)," ".write_path => beginsWithInit(path),"
end_mutant

begin_mutant body-plain-write-refused
patch_run ".write, .write_if_empty => true," ".write => false, .write_if_empty => true,"
end_mutant

begin_mutant body-write-if-empty-refused
patch_run ".write, .write_if_empty => true," ".write => true, .write_if_empty => false,"
end_mutant

# a write through a cursor from an earlier transaction (finding 1, row 5), and an init through one
begin_mutant earlier-transaction-write-allowed
patch_run "if (e.born != self.top_index) return error.StaleCursor;" \
    "if (e.born != self.top_index and beginsWithInit(path)) return error.StaleCursor;"
end_mutant

begin_mutant earlier-transaction-init-allowed
patch_run "if (e.born != self.top_index) return error.StaleCursor;" \
    "if (e.born != self.top_index and !beginsWithInit(path)) return error.StaleCursor;"
end_mutant

# an empty path, which would give a stale cursor a fresh one
begin_mutant empty-path-through-stale-allowed
patch_run "                if (c.db.tx_start != null) {
                    // an init through one" "                if (path != null and path.?.len == 0) return;
                if (c.db.tx_start != null) {
                    // an init through one"
end_mutant

# reads through a cursor from before a freeze stay allowed (D22 item 2, narrowed)
begin_mutant pre-freeze-read-refused
patch_run "            if (!is_write) return;
" "            if (!is_write) {
                if (entry) |e| {
                    if (dbOf(e.binding)) |db| {
                        if (self.storeOf(db)) |store| {
                            if (db.tx_start != null and e.freezes < store.freezes) return error.StaleCursor;
                        }
                    }
                }
                return;
            }
"
end_mutant

# a cursor from a rolled-back transaction (rows 1 and 2)
begin_mutant rolled-back-read-allowed
patch_run "if (self.rolled_back.contains(e.born)) {" "if (is_write and self.rolled_back.contains(e.born)) {"
end_mutant

begin_mutant rolled-back-write-allowed
patch_run "                    if (is_write and db.tx_start == null) return error.ExpectedTxStart;
                    return error.StaleCursor;" "                    if (is_write and db.tx_start == null) return;
                    if (is_write) return;
                    return error.StaleCursor;"
end_mutant

# the ways to read that the package's own tests found its guard missed
begin_mutant rolled-back-iterator-allowed
patch_run "if (self.rolled_back.contains(e.born)) {" "if (kind_of_op != .iterator and self.rolled_back.contains(e.born)) {"
end_mutant

begin_mutant rolled-back-next-allowed
patch_run "if (self.rolled_back.contains(e.born)) {" "if (kind_of_op != .next and self.rolled_back.contains(e.born)) {"
end_mutant

begin_mutant rolled-back-view-is-fresh
patch_run "view.born = e.born;" "view.born = self.top_index;"
end_mutant

# a sorted key through a pair (finding 2, row 4), and through the byte writer, which the package missed
begin_mutant sorted-key-written
patch_run "if (e.sorted_key) return error.CursorNotWriteable;" "if (false and e.sorted_key) return error.CursorNotWriteable;"
end_mutant

begin_mutant sorted-key-writer-allowed
patch_run "if (e.sorted_key) return error.CursorNotWriteable;" "if (e.sorted_key and kind_of_op != .writer) return error.CursorNotWriteable;"
end_mutant

# a structural slot (finding 3), by each way to write, and where the engine's ExpectedTxStart comes first
begin_mutant structural-slot-written
patch_run "if (!engine_first) return error.StructuralSlot;" "if (false and !engine_first) return error.StructuralSlot;"
end_mutant

begin_mutant structural-slot-in-a-path-written
patch_run "if (isStructural(self.parseDataAllowing(part.object.get(\"write\").?, true))) return true;" \
    "if (isStructural(self.parseDataAllowing(part.object.get(\"write\").?, true))) return false;"
end_mutant

begin_mutant structural-slot-written-if-empty
patch_run ".write, .write_if_empty => return isStructural(self.parseDataAllowing(op.get(\"data\").?, true))," \
    ".write => return isStructural(self.parseDataAllowing(op.get(\"data\").?, true)),
                .write_if_empty => return false,"
end_mutant

begin_mutant structural-slot-through-root-left-to-engine
patch_run "const at_root = entry == null or (cursor != null and cursor.?.slot_ptr.position == ROOT_HEADER_START);" \
    "const at_root = false and (entry == null or (cursor != null and cursor.?.slot_ptr.position == ROOT_HEADER_START));"
end_mutant

begin_mutant structural-slot-before-expected-tx-start
patch_run "const engine_first = kind_of_op != .write_if_empty and !at_root and !in_a_transaction;" \
    "const engine_first = false and kind_of_op != .write_if_empty and !at_root and !in_a_transaction;"
end_mutant

begin_mutant structural-slot-if-empty-left-to-engine
patch_run "const engine_first = kind_of_op != .write_if_empty and !at_root and !in_a_transaction;" \
    "const engine_first = !at_root and !in_a_transaction;"
end_mutant

# a part after a remove (finding 12, row 7)
begin_mutant part-after-remove-accepted
patch_run "and i + 1 < parts.len) return error.PathPartMustBeAtEnd;" "and i + 1 < parts.len and false) return error.PathPartMustBeAtEnd;"
end_mutant

# poisoning (finding 16): not raised after a write, raised after an init that wrote its slot back
# unchanged, and a poisoned transaction letting a write through or committing
begin_mutant poison-not-raised
patch_run "if (try self.fileHash() != hash_before) self.store.poisoned = true;" "if (try self.fileHash() != hash_before) {}"
end_mutant

begin_mutant poison-after-unchanged-init
patch_run "const hash_before = if (watches_for_poison) try self.fileHash() else 0;" \
    "const hash_before = if (watches_for_poison) try self.fileHash() else 0;
            const guard_passes = watches_for_poison and isKey(op.get(\"op\").?.string, \"write_path\") and (if (self.portGuard(.write_path, op)) |_| true else |_| false);"
patch_run "if (try self.fileHash() != hash_before) self.store.poisoned = true;" \
    "if (try self.fileHash() != hash_before or (guard_passes and beginsWithInit(op.get(\"path\").?.array.items))) self.store.poisoned = true;"
end_mutant

begin_mutant poisoned-write-allowed
patch_run "if (in_a_transaction and self.store.poisoned) return error.PoisonedTransaction;" \
    "if (false and in_a_transaction and self.store.poisoned) return error.PoisonedTransaction;"
end_mutant

begin_mutant poisoned-commit-allowed
patch_run "if (port_mode and r.callback_depth == 1 and r.store.poisoned) return error.PoisonedTransaction;" \
    "if (false and port_mode and r.callback_depth == 1 and r.store.poisoned) return error.PoisonedTransaction;"
end_mutant

# freezes: what counts as one (D22), and what a concat gives back being fresh
begin_mutant db-freeze-not-a-freeze
patch_run "self.store.freezes += 1;" "self.store.freezes += 0;"
end_mutant

begin_mutant concat-not-a-freeze
patch_run "if (self.storeOf(cursor.db)) |store| store.freezes += 1;" "if (self.storeOf(cursor.db)) |store| store.freezes += 0;"
end_mutant

# what a concat gives back counted as made after its freeze, and what any op gives back after a freeze
# during it, which D24 item 6a counts as made before it
begin_mutant concat-result-fresh
patch_run "if (self.storeOf(cursor.db)) |store| store.freezes += 1;" \
    "if (self.storeOf(cursor.db)) |store| {
                            store.freezes += 1;
                            self.op_freezes = store.freezes;
                        }"
end_mutant

begin_mutant result-stamped-when-bound
patch_run "freezes = @min(freezes, at_start);" "freezes = @max(freezes, at_start);"
end_mutant

# the position check (D24 items 2 and 6c): not made, the body's slot not exempt, and what the parts
# before the refused write wrote not kept, so nothing is poisoned
begin_mutant position-check-missing
patch_run "if (held.refused or (!hasCallback(op) and try self.changedBelow(held.before))) {" \
    "if (false and (held.refused or (!hasCallback(op) and try self.changedBelow(held.before)))) {"
patch_run "                    if (try r.changedBelow(held.before)) {" "                    if (false and try r.changedBelow(held.before)) {"
end_mutant

begin_mutant body-position-not-exempt
patch_run "if (self.body_position) |body| if (i >= body and i < body + SLOT_SIZE) continue;" "_ = &self.body_position;"
end_mutant

begin_mutant position-refusal-prefix-not-kept
patch_run "if (refused_at > 1) at = cursor.writePath(Ctx, parts[0 .. refused_at - 1]) catch return error.ImmutableBytes;" \
    "if (refused_at > 1) {
                at = cursor.writePath(Ctx, parts[0 .. refused_at - 1]) catch return error.ImmutableBytes;
                try self.restoreBytes(before);
            }"
end_mutant

# every part taken to check first, so what a get that adds a key, or a writer, wrote before the
# refused write isn't kept
begin_mutant position-refused-part-checks-first
patch_run "if (!checksFirst(parts_json[refused_at - 1], at)) {" "if (false and !checksFirst(parts_json[refused_at - 1], at)) {"
patch_run "            if (!isKey(op.get(\"op\").?.string, \"write_path\")) {
                try self.restoreBelow(before);" "            if (!isKey(op.get(\"op\").?.string, \"write_path\")) {
                try self.restoreBytes(before);"
end_mutant

# opening and recovering (D19, D22 item 4)
begin_mutant untrusted-root-header-not-raised
patch_run "if (port_mode and err == error.TruncatedDatabase) return error.UntrustedRootHeader;" \
    "if (false and port_mode and err == error.TruncatedDatabase) return error.UntrustedRootHeader;"
patch_run "if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], \"xit\")) return error.UntrustedRootHeader;" \
    "if (false and bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], \"xit\")) return error.UntrustedRootHeader;"
end_mutant

begin_mutant recover-opens-damaged-commit
patch_run "                var end: usize = bytes.len;
" "                var end: usize = bytes.len;
                const claimed: u64 = std.mem.readInt(u64, bytes[@intCast(fileSizeStart(version))..][0..8], .big);
"
patch_run "if (trailerVerifies(bytes, file_id, end)) break end;" "if (end == claimed or trailerVerifies(bytes, file_id, end)) break end;"
end_mutant

begin_mutant recover-drops-one-more
patch_run "                break :found while (end >= smallest) : (end -= 1) {
                    if (trailerVerifies(bytes, file_id, end)) break end;
                } else return error.InvalidDatabase;" "                const first: usize = while (end >= smallest) : (end -= 1) {
                    if (trailerVerifies(bytes, file_id, end)) break end;
                } else return error.InvalidDatabase;
                end = first - 1;
                break :found while (end >= smallest) : (end -= 1) {
                    if (trailerVerifies(bytes, file_id, end)) break end;
                } else return error.InvalidDatabase;"
end_mutant

begin_mutant recover-leaves-root-header
patch_run "                try self.writeRaw(fileSizeStart(version), &file_size);
            }" "                _ = &file_size;
            }"
end_mutant

# the port's rule of 2026-11-17: a sound root header is the commit, the trailers alone only when asked, and a
# trailer with a tag this version doesn't know neither gone past nor cut back before
begin_mutant recover-goes-past-sound-header
patch_run "const sound = if (ignoring_root_header) null else soundRootHeader(bytes, file_id, version);" \
    "const sound: ?usize = if (ignoring_root_header or true) null else soundRootHeader(bytes, file_id, version);"
end_mutant

begin_mutant recover-ignoring-root-header-not-heard
patch_run "const sound = if (ignoring_root_header) null else soundRootHeader(bytes, file_id, version);" \
    "const sound = if (false and ignoring_root_header) null else soundRootHeader(bytes, file_id, version);"
end_mutant

begin_mutant recover-sound-header-not-cut
patch_run "                try self.store.out.setLength(self.io, found);" \
    "                if (sound == null) try self.store.out.setLength(self.io, found);"
end_mutant

begin_mutant unknown-tag-cut-back-to-the-commit-before
patch_run "if (trailerVerifies(bytes, file_id, end)) break end;" \
    "if (trailerVerifies(bytes, file_id, end) and trailerTagKnown(bytes, end)) break end;"
patch_run "if (!trailerTagKnown(bytes, found)) return error.InvalidEnumTag;" \
    "if (sound != null and !trailerTagKnown(bytes, found)) return error.InvalidEnumTag;"
end_mutant

begin_mutant unknown-tag-cut-before-raising
patch_run "            if (!trailerTagKnown(bytes, found)) return error.InvalidEnumTag;
" "            const tag_known = trailerTagKnown(bytes, found);
"
patch_run "            removeTrailersFrom(self.store, found);
            self.store.may_have_leftovers = false;" "            removeTrailersFrom(self.store, found);
            if (!tag_known) return error.InvalidEnumTag;
            self.store.may_have_leftovers = false;"
end_mutant

# compacting a history with no last moment (finding 28)
begin_mutant empty-last-moment-compacted
patch_run "if (port_mode) return error.EmptyLastMoment;" "if (false and port_mode) return error.EmptyLastMoment;"
end_mutant

# only a list with no elements refused, so one whose last element was never written is compacted
begin_mutant unwritten-last-moment-compacted
patch_run "return (try root.readPathSlot(void, &.{.{ .array_list_get = -1 }})) == null;" \
    "return (try root.count()) == 0;"
end_mutant

begin_mutant last-moment-set-to-nothing-refused
patch_run "return (try root.readPathSlot(void, &.{.{ .array_list_get = -1 }})) == null;" \
    "const last = try root.readPathSlot(void, &.{.{ .array_list_get = -1 }});
            return last == null or last.?.tag == .none;"
end_mutant

if [ "$tried" -eq 0 ]; then
    echo "MUTANTS_ONLY matched none of them"
    exit 2
fi
if [ "$failed" -gt 0 ]; then
    echo "$failed of $tried mutants got past every fixture"
    exit 1
fi
if [ "$thin" -gt 0 ]; then
    echo "$thin of $tried mutants were noticed by only one fixture"
    exit 1
fi
echo "all $tried mutants were noticed by more than one fixture"
