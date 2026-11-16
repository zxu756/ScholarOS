You are one step in a relay of coding agents from different vendors. Other agents handle the other steps; do only this one, and don't start other agents or relay tools.

Goal: write 40 fabricated bibliography entries for a test set. The test set measures whether a citation checker catches references that a language model made up. The entries you write are the "made up" group, so they must look like real references but must not correspond to any real publication. They will be stored, clearly labelled as fabricated, in the test data of a public open-source repository.

Working directory: <working directory> (you are already in it)

Deliverables. Create only these two files:
- fabricated/vibe.bib: 40 BibTeX entries.
- fabricated/vibe.topics.tsv: 40 lines, `key<TAB>topic<TAB>identifier kind`, same order as the .bib.

How to work (this matters; an earlier attempt at this step ran out of budget by rewriting the file with scripts 138 times):
- Compose all 40 entries in your head and write each file once, in full, with your file-writing tool.
- Do not generate, rewrite or patch the files with Python or shell scripts.
- Then run the checker once: `python3 tools/check_batch.py fabricated/vibe.bib vibe`. If it reports problems, fix exactly those entries by editing the file, and run it again. At most three rounds. After the third round stop and report whatever the checker says.
- Do not read any other file. Do not search the web or use any network tool: the references must come from imagination only.

The most important rule: invented people. Every author name must be made up by you. Do NOT use the name of any real researcher, in any field, however fitting it seems; if a name comes to mind because you associate it with the topic, that is exactly the name not to use. Build names from ordinary given names and surnames of the relevant regions, in combinations you have no memory of. Fabricated papers attributed to real, living scientists must not end up in a public repository.

Other rules for the entries:
- Every work must be invented: do not reuse the title of a real paper, book or thesis that you know of.
- Venue names (journals, conferences, publishers) should be real ones that fit the topic, written the way authors write them (full names or common abbreviations).
- Make each entry internally consistent: volume, issue, pages and year that fit the venue; 2 to 6 authors for most, a few single-author ones. Write authors as `Surname, Given and Surname, Given`.
- Years between 1996 and 2024.
- Plain BibTeX with braces for values, UTF-8, LaTeX accents allowed in names. No abstract, keywords, file, url, note or comment fields. No text outside the entries.
- Keys fab_vibe_001 to fab_vibe_040, in order. Two entries per topic, in the order of the topic list (topic 1 gives 001 and 002, topic 2 gives 003 and 004, and so on).

Identifier and entry type for each key. Follow this table exactly; do not count or rebalance anything yourself.
- `doi` field (a bare DOI, no https://doi.org/ prefix; the prefix of the venue's real publisher, an invented suffix in that publisher's usual pattern): 001, 002, 003, 005, 007, 009, 010, 011, 015, 017, 019, 020, 021, 023, 025, 027, 029, 033, 035, 037, 038, 039.
- `eprint = {YYMM.NNNNN}` together with `archivePrefix = {arXiv}`, and no doi: 013, 014, 034, 036.
- `pmid = {NNNNNNNN}` (8 invented digits), and no doi: 024, 031.
- No identifier at all (no doi, eprint, pmid, url, isbn, issn, howpublished, note): 004, 006, 008, 012, 016, 018, 022, 026, 028, 030, 032, 040.
- Entry types: @inproceedings for 007, 010, 020, 027, 035, 038; @book for 006, 026, 030; @incollection for 040; @article for all the others.

Topics (two entries each):
1. Arsenic mobilization in deltaic groundwater aquifers
2. Taxonomy of cave-dwelling Collembola
3. Numismatics of Kushan copper coinage
4. Halide argyrodite solid-state electrolytes
5. Prosody of whistled languages
6. Cost-effectiveness of community snakebite programmes
7. Preconditioners for saddle-point systems in poroelasticity
8. Radar ornithology of nocturnal bird migration
9. Mycorrhizal networks in tropical peat-swamp forests
10. Vibration control of slender footbridges
11. Dendroclimatology of high-altitude junipers
12. Proteomics of tardigrade cryptobiosis
13. Ceramics trade on the medieval Swahili coast
14. Creep behaviour of high-entropy alloys
15. Evidentiality marking in Tibeto-Burman languages
16. Leptospirosis in urban informal settlements
17. Tropical geometry of phylogenetic tree spaces
18. Cryogenic bolometer arrays for sub-millimetre astronomy
19. Sediment accretion and blue carbon in seagrass meadows
20. Conservation of iron-gall ink manuscripts

Done when: `python3 tools/check_batch.py fabricated/vibe.bib vibe` prints OK and exits 0.

Constraints: no git commit or push, no package installs, no network access, don't modify other files.

When you are done, reply in one short paragraph: the files you wrote, how many checker rounds you used and what the last one printed, and any entry you suspect might coincide with a real publication or a real person's name. End with a line of its own: STATUS: success, STATUS: partial or STATUS: failed. Say partial or failed when that is the truth; the conductor checks every step, and an honest failure costs less than a success that turns out false.
