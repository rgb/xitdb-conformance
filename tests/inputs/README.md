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

In a version 1 file, the root header is a copy of the root slot at bytes 20 to 28, which the original no longer reads
or writes, and the committed size at 29. Committed data starts at 37.
