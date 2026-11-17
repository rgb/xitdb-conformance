# Inputs

Files that scripts start from: `raw_load` puts one in place of a database's file while it's closed
(`SCRIPT-FORMAT.md` section 5). They aren't expected files, and nothing regenerates them. `fixtures.sh` copies them to
`fixtures/inputs/` as they are, where they keep these names whichever Zig commit the fixtures follow.

The `v1-*` files are version 1 databases, which the original wrote at `6b93af1af3a260399fa0a0b1b268ded2cbf5eec5`, the
last commit before format version 2 (`bdaa55e`). The original no longer creates version 1, so these can't be made
again, and they're kept as they were.

| Input | Bytes | SHA-256 | Where it came from | What's in it |
|---|---|---|---|---|
| `v1-new` | 62 | `c536ee3b15cc812383b2066974b37a213700cf45b5c178aed22ff6cfff86f4b0` | `fixtures/valid/compact-roots--port.s_empty.db` at 6b93af1 | a new database: file ID `0000000000000010`, hash ID `sha1`, hash size 20, an empty root committed with commit ID 0 |
| `v1-history` | 1215 | `8bbc541613545da8235ab34cdd4f5a5c9559816e924a8b019038339cb3202978` | `fixtures/valid/01-list-root-hash-map.db` at 6b93af1 | `scripts/01-list-root-hash-map.json`: a list at the root with two moments, each a hash map with one value of every kind. Two commits after the first. File ID `c0f0000000000001`, hash ID `sha1` |
| `v1-unwritten-last` | 838 | `107b794c3753c22880afa20aaced9976d282db53e47552873a3cf237451a626c` | `fixtures/valid/compact-roots--port.s_three_written.db` at 6b93af1 | a list at the root with moments 1, 2 and 3, and a fourth appended and never written, which at 6b93af1 is a truly empty slot (`none`, `full` not set). File ID `0000000000000036` |
| `v1-holes` | 3559 | `e5afadda325a093a04efc345d0aaa6a6956c01925376fd57e879247818615f29` | `fixtures/valid/reads-iterators.db` at 6b93af1 | `tests/valid/reads-iterators.json` as it was at 6b93af1: a history whose moment holds every kind of collection, and `holes`, an array list of four whose elements 0 and 2 were appended and never written, so truly empty. File ID `0011223344556677` |
| `v1-one-unwritten` | 256 | `25d8c58f3e77cfd23557e74212513d95ec95bc27529fa4c26beac5fce9cdd5d9` | `compact-roots.s_unwritten_last.db` from `tests/valid/compact-roots.json` as it was at e7f4c0d, run at 6b93af1 | a list at the root of one element, appended and never written, so truly empty. File ID `0000000000000024` |
| `v1-sliced-holes` | 450 | `082502939256caa2fc1c846fc6f0690a6ac037fbceced81a11ed14fbf21afc8d` | `tests/port-differs/iterator-past-slice.zig.json` as it was at e7f4c0d, run at 6b93af1 with `--allow-port-differences` | a list at the root that was `[never written, 1, 2, 3]` and was sliced to a size of 2, so its element 0 is truly empty and its blocks still hold 2 and 3 past the end. File ID `0011223344556677` |

The `sorted-*` and `linked-*` files are clones that the freeze hazard left in a committed file with no byte damaged:
two headers for one tree, an undefined use (`SCRIPT-FORMAT.md` section 10). Each was made once, on the original at
`89da8e76f0dd82baefeadb656f0f734bf920be05`, by the maker named, which `check.sh` runs with the rest of `tests/undefined/`.
In each, a moment holds the collections and their clones, made the README's way: the clone's slot is the original's, the
cursor to it is frozen, and its init copies the header. Then, through the original, which isn't frozen, ten changes land in
place in the nodes they share. Where the clone wrote first, its write copied its root and the nodes on its way, so its
header and root agree, and the leaves they still share hold another number than the root counts for them. A valid script
reads these files, as the scripts in `tests/valid/` with the same names do. Since `274418f` it can write to a linked one
too, as `linked-*-writes` do, where each write succeeds or raises `InvalidBTreeNode`; at `89da8e7` some writes there
panicked. Writing to a sorted one stays an undefined use, as a remove can still underflow its count.

| Input | Bytes | SHA-256 | Where it came from | What's in it |
|---|---|---|---|---|
| `sorted-header-above-tree` | 3789 | `bb4c3c3cb12d777b62b93d9fd8d00ce756a1c6ee590baf35239149453d307bb3` | `tests/undefined/frozen-clone-sorted-header-above-tree.json`, run once on the original at 89da8e7 | a sorted map and a sorted set of k00 to k40, and their clones; then k03, k07 … k39 removed through the originals, in one transaction that commits. The clone's header says 41 over a tree of 31, whole in itself; the original's header and tree are 31 and 31 |
| `sorted-header-below-tree` | 3969 | `57ef1a619e27a30c25f44a9352ce41e4a9c70e7d00b6ad2fd153390127ebff84` | `tests/undefined/frozen-clone-sorted-header-below-tree.json`, run once on the original at 89da8e7 | the same, then k035, k075 … k395 added through the originals, each just after a key that's there, in one transaction that commits. The clone's header says 41 under a tree of 51, whole in itself; the original's header and tree are 51 and 51 |
| `sorted-counts-above-leaves` | 4935 | `153b17c27a118b95c0db262e6929e1b7a09b3ae43b255cc7d43bcd71b20298b6` | `tests/undefined/frozen-clone-sorted-counts-above-leaves.json`, run once on the original at 89da8e7 | the same, but each clone writes first (the map's writes k00 again, the set's adds k005), and then the originals remove k03 … k39, in one transaction that commits. The clone's header says 41 for the map and 42 for the set, which its root agrees with, over leaves that hold 33 and 34; the original's header and tree are 31 and 31 |
| `sorted-counts-below-leaves` | 5115 | `f837030acf3cdb58fd8f255bb7bb3aa124eb2eee419f89b3072de0a56b7efa33` | `tests/undefined/frozen-clone-sorted-counts-below-leaves.json`, run once on the original at 89da8e7 | the same, with k035 … k395 added through the originals after the clones' writes, in one transaction that commits. The clone's header says 41 and 42, which the root agrees with, over leaves that hold more; the original's header and tree are 51 and 51 |
| `linked-header-above-tree` | 1507 | `fb924a772d14910d055aa87cb8ae3fe670ff7bae6f71f250227793774f424c68` | `tests/undefined/frozen-clone-linked-header-above-tree.json`, run once on the original at 89da8e7 | a linked array list of 0 to 40 and its clone; then the elements at 36, 32 … 0 removed through the original, in one transaction that commits. The clone's header says 41 over a tree of 31; the original's header and tree are 31 and 31 |
| `linked-header-below-tree` | 1653 | `206c1d4a761328b47e5163a1e5adb4f394f74bb8a5d81e1b0d7c4ecd0d6bf81f` | `tests/undefined/frozen-clone-linked-header-below-tree.json`, run once on the original at 89da8e7 | the same, then 1000 to 1009 appended through the original, in one transaction that commits. The clone's header says 41 under a tree of 51; the original's header and tree are 51 and 51 |
| `linked-counts-above-leaves` | 1927 | `9935894e24d746bbdbd7f6fbbb75676d2a42b3a7d252e0fd48c20beb44db876c` | `tests/undefined/frozen-clone-linked-counts-above-leaves.json`, run once on the original at 89da8e7 | the same, but the clone writes element 0 again first, and then the original removes the elements at 36, 32 … 0, in one transaction that commits. The clone's header says 41, which its root agrees with, over leaves that hold fewer; the original's header and tree are 31 and 31 |
| `linked-counts-below-leaves` | 2073 | `40bd4abaaba801572532147c6796e4547a36238863b283c58dba771f9facd79c` | `tests/undefined/frozen-clone-linked-counts-below-leaves.json`, run once on the original at 89da8e7 | the same, with 1000 to 1009 appended through the original after the clone's write, in one transaction that commits. The clone's header says 41, which its root agrees with, over leaves that hold more; the original's header and tree are 51 and 51 |

In a version 1 file, the root header is a copy of the root slot at bytes 20 to 28, which the original no longer reads
or writes, and the committed size at 29. Committed data starts at 37.
