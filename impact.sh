#!/bin/sh
# Keeps the lists in PORT-IMPACT.md, of which scripts rely on what the port will change after
# its parity gate.
#
#   ./impact.sh                changes the lists in PORT-IMPACT.md to what the scripts do now
#   ./impact.sh --check        changes nothing, and fails if they aren't
#   ./impact.sh --prototypes   builds copies of Zig with some of those changes made, and says
#                              which scripts each one affects. It isn't part of the gate
#
# The lists come from `run --note-port-changes` on every script in this repository. They say
# what each script does, in order to know what each change would do to it, so they're in the
# gate: a new script that relies on one of these has to show up.

set -eu
cd "$(dirname "$0")"

RUN=$PWD/zig-out/bin/run
# check.sh points this at a copy to show that --check notices a list out of date
DOC=${IMPACT_DOC:-PORT-IMPACT.md}
TMP=out/impact
rm -rf "$TMP"
mkdir -p "$TMP"

MODE=update
case "${1:-}" in
    "") ;;
    --check) MODE=check ;;
    --prototypes) MODE=prototypes ;;
    *)
        echo "usage: ./impact.sh [--check | --prototypes]"
        exit 2
        ;;
esac

if [ "$MODE" = prototypes ]; then
    DET=$PWD/zig-out/bin/detcheck
    ZIG_ORIGINAL=${ZIG_ORIGINAL:-../../xitdb}
    mkdir -p "$TMP/reference" "$TMP/zig"
    git -C "$ZIG_ORIGINAL" archive HEAD src | tar -x -C "$TMP/zig"
    # what run --version says a prototype's runner was built from
    printf 'pub const xitdb_commit = "%s (src/lib.zig as impact.sh --prototypes changes it)";\npub const conformance_commit = "%s";\n' \
        "$(git -C "$ZIG_ORIGINAL" rev-parse HEAD)" "$(git rev-parse HEAD)" > "$TMP/build_options.zig"
    cp "$TMP/zig/src/lib.zig" "$TMP/lib.original.zig"
    SCRIPTS=$(ls scripts/*.json tests/valid/*.json tests/generated/*.json)
    for script in $SCRIPTS; do
        "$RUN" "$script" "$TMP/reference/$(basename "$script" .json).db"
    done

    patch_lib() { # old text, new text
        OLD=$1 NEW=$2 perl -0777 -pi -e '
            BEGIN { $old = $ENV{OLD}; $new = $ENV{NEW}; $n = 0; }
            $n = s/\Q$old\E/$new/g;
            END { die "patch: \"$old\" appears $n times\n" if $n != 1; }
        ' "$TMP/zig/src/lib.zig"
    }

    # after however many patches have been made since the last time
    try_prototype() { # name
        zig build-exe --dep xitdb --dep build_options -Mroot=src/run.zig "-Mxitdb=$TMP/zig/src/lib.zig" "-Mbuild_options=$TMP/build_options.zig" \
            "-femit-bin=$TMP/run-prototype" --cache-dir "$TMP/cache" 2> "$TMP/build.err" || {
            echo "$1: it doesn't build:"
            head -n 8 "$TMP/build.err"
            exit 1
        }
        different=
        failing=
        for script in $SCRIPTS; do
            name=$(basename "$script" .json)
            if ! perl -e 'alarm shift; exec @ARGV' 30 "$TMP/run-prototype" "$script" "$TMP/p.db" > /dev/null 2> "$TMP/p.err"; then
                failing="$failing $name"
            elif ! "$DET" "$TMP/reference/$name.db" "$TMP/p.db" > /dev/null 2>&1; then
                different="$different $name"
            fi
            rm -f "$TMP"/p.*
        done
        echo "$1"
        echo "  different bytes:${different:- none}"
        echo "  fail:${failing:- none}"
        cp "$TMP/lib.original.zig" "$TMP/zig/src/lib.zig"
    }

    # finding 12: an error if anything follows a remove
    patch_lib ".hash_map_remove => |key_hash| {" ".hash_map_remove => |key_hash| {
                    if (path.len > 1) return error.PathPartMustBeAtEnd;"
    patch_lib ".sorted_map_remove => |key| {" ".sorted_map_remove => |key| {
                    if (path.len > 1) return error.PathPartMustBeAtEnd;"
    try_prototype "12: an error if anything follows a remove"

    # finding 17: write_if_empty goes by the slot as it is now
    patch_lib "const slot_ptr = try self.resolved();
                    if (slot_ptr.slot.empty()) {
                        try self.write(data);" "var slot_ptr = try self.resolved();
                    if (slot_ptr.position) |position| {
                        var position_reader = self.db.core.reader();
                        try position_reader.seekTo(position);
                        slot_ptr.slot = @bitCast(try takeInt(&position_reader.interface, SlotInt, .big));
                    }
                    if (slot_ptr.slot.empty()) {
                        try self.write(data);"
    try_prototype "17: write_if_empty goes by the slot as it is now"

    # finding 23: a cursor's freeze holds for every cursor, by being a freeze of the database
    patch_lib "self.frozen_at = try self.db.core.length();" "self.frozen_at = try self.db.core.length();
                    self.db.tx_start = self.frozen_at;"
    try_prototype "23: a cursor's freeze is a freeze of the database"
    exit 0
fi

# one line for each script and change: the change, the script, and how many ops
for script in scripts/*.json tests/valid/*.json tests/generated/*.json tests/failing/*.json tests/invalid/*.json tests/port-differs/*.json tests/undefined/*.json tests/dump/*.json tests/bench/*.json tests/from-other-zig/*.json; do
    # another commit's version of a script that's listed already, which this Zig can't get to the end of
    case "$script" in *--*) continue ;; esac
    name=${script%.json}
    # the memory kind is the one that can tell what a failed op left behind
    kind=memory
    if grep -q '"read_only": *true' "$script"; then kind=buffered_file; fi
    { "$RUN" "$script" "$TMP/x.db" --kind "$kind" --allow-port-differences --note-port-changes 2>&1 || true; } |
        grep '^change ' | awk -v name="$name" '{ count[$2]++ } END { for (id in count) print id, name, count[id] }' >> "$TMP/all.txt" || true
    # some in tests/undefined crash the engine, which the shell would otherwise remark on
done 2> /dev/null
# what `run` refuses, so no script gets as far as doing it
for script in tests/invalid/*.json; do
    if grep -q "can't be written" "$script"; then echo "3 ${script%.json} 1" >> "$TMP/all.txt"; fi
done
LC_ALL=C sort -k1,1 -k2,2 "$TMP/all.txt" > "$TMP/sorted.txt"

# what goes in a list: a line per folder
list_for() { # id
    awk -v id="$1" '
        $1 == id {
            folder = $2; sub(/\/[^\/]*$/, "", folder)
            name = $2; sub(/.*\//, "", name)
            if (!(folder in seen)) { order[++n] = folder; seen[folder] = 1 }
            text[folder] = text[folder] (text[folder] == "" ? "" : ", ") name " (" $3 ")"
        }
        END {
            if (n == 0) print "- none"
            for (i = 1; i <= n; i++) print "- `" order[i] "`: " text[order[i]]
        }
    ' "$TMP/sorted.txt"
}

# PORT-IMPACT.md with each list as it is now
while IFS= read -r line; do
    case "$line" in
        "<!-- list "*" -->")
            echo "$line"
            id=${line#<!-- list }
            id=${id% -->}
            list_for "$id"
            skipping=yes
            ;;
        "<!-- end -->")
            echo "$line"
            skipping=no
            ;;
        *)
            if [ "${skipping:-no}" != yes ]; then echo "$line"; fi
            ;;
    esac
done < "$DOC" > "$TMP/doc.md"

# a change with scripts that the document has no list for would go unnoticed
for id in $(awk '{ print $1 }' "$TMP/sorted.txt" | sort -u); do
    grep -qF "<!-- list $id -->" "$DOC" || {
        echo "impact: $DOC has no list for $id"
        exit 1
    }
done

if [ "$MODE" = check ]; then
    cmp -s "$TMP/doc.md" "$DOC" || {
        echo "impact: the lists in $DOC aren't what the scripts do. Run ./impact.sh"
        diff "$DOC" "$TMP/doc.md" | head -n 20 | cut -c1-160
        exit 1
    }
    echo "$DOC: its lists are what the scripts do"
else
    cp "$TMP/doc.md" "$DOC"
    echo "$DOC: its lists are up to date"
fi
