You are one step in a relay of coding agents from different vendors. Other agents handle the other steps; do only this one, and don't start other agents or relay tools.

Goal: write 40 fabricated bibliography entries for a test set. The test set measures whether a citation checker catches references that a language model made up. The entries you write are the "made up" group, so they must look like real references but must not correspond to any real publication. They will be stored, clearly labelled as fabricated, in the test data of an open-source project.

Working directory: <working directory> (you are already in it)

Inputs from earlier steps:
- tools/check_batch.py: a format checker you can run on your output (no network).

Deliverables. Create only these two files:
- fabricated/codex.bib: 40 BibTeX entries.
- fabricated/codex.topics.tsv: 40 lines, `key<TAB>topic<TAB>identifier kind`, same order as the .bib.

How to write the entries:
- Work from imagination only. Do not search the web, do not call any network tool, and do not look anything up. The point is that these references come from a model's head.
- Every work must be invented: do not reuse the title of a real paper, book or thesis that you know of. Invent the author names too, plausible for the field and region, and do not use the names of real well-known researchers. Venue names (journals, conferences, publishers) should be real ones that fit the topic, written the way authors write them (full names or common abbreviations).
- Make each entry internally consistent, the way a careful but hallucinating model would: volume, issue, pages and year that fit the venue; 2 to 6 authors for most, a few single-author ones.
- Years between 1996 and 2024.
- Entry types: mostly @article, about six @inproceedings, and three or four @book or @incollection (put these among the entries that have no identifier).
- Keys: fab_codex_001 to fab_codex_040, in order.
- Two entries per topic, in the order of the topic list below (topic 1 gives 001 and 002, topic 2 gives 003 and 004, and so on).
- Identifiers. Exactly this mix over the 40 entries, and never two kinds on one entry:
  - 22 entries with a `doi` field: a bare DOI (no https://doi.org/ prefix) whose prefix belongs to the real publisher of the venue you named and whose suffix is invented in that publisher's usual pattern.
  - 4 entries with `eprint = {YYMM.NNNNN}` and `archivePrefix = {arXiv}` (invented number in the new-style format). Use these for the mathematical, physical or computational topics.
  - 2 entries with `pmid = {NNNNNNNN}` (8 invented digits). Use these for biomedical topics.
  - 12 entries with no identifier at all: no doi, eprint, pmid, url, isbn, issn, howpublished or note field.
- No abstract, keywords, file, url or comment fields. No text outside the entries (no comments, no headings).
- Plain BibTeX with braces for values, UTF-8, LaTeX accents allowed in names.

Topics (two entries each):
1. Varve chronology of proglacial lake sediments
2. Lichen biogeography on sub-Antarctic islands
3. Paleography of medieval Icelandic manuscripts
4. Humidity-driven degradation of lead-free perovskite solar absorbers
5. Morphological segmentation for low-resource Uralic languages
6. Health economics of rural tele-ophthalmology screening
7. Spectral methods for non-normal sparse matrices
8. Passive acoustic monitoring of beaked whales
9. Soil nematode communities under no-till farming
10. Seismic retrofitting of unreinforced masonry minarets
11. Tephrochronology of Kamchatka peat bogs
12. Desiccation tolerance in bryophytes
13. Ottoman-era cadastral maps and land tenure
14. Fatigue of additively manufactured titanium lattice structures
15. Tone sandhi in Hmong-Mien languages
16. Antimicrobial resistance in aquaculture ponds
17. Ergodic theory of interval exchange transformations
18. Fibre-optic distributed temperature sensing in boreholes
19. Pollination networks in alpine meadows
20. Corrosion of bronze artefacts in marine burial environments

Done when: `python3 tools/check_batch.py fabricated/codex.bib codex` prints OK and exits 0. Run it yourself and fix what it reports.

Constraints: no git commit or push, no package installs, no network access, don't modify other files.

When you are done, reply in one short paragraph: the files you wrote, the command you ran to check your work and what it printed, and anything the next step should know (for example any entry you suspect might coincide with a real publication). End with a line of its own: STATUS: success, STATUS: partial or STATUS: failed. Say partial or failed when that is the truth; the conductor checks every step, and an honest failure costs less than a success that turns out false.
