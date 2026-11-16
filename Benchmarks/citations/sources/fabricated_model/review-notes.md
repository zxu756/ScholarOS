# Second review, fabricated group (2026-11-15 UTC)

Reviewer: Claude Sonnet (subagent, second reviewer). Inputs: evidence-digest.md (read in full), search-summary.tsv, plus 25 web searches.

## Counts
- no_such_work: 39
- identifier_belongs_to_other_work: 41
- matches_real_work: 0
- unsure: 0

Verdicts agree with the first check. The `matched_work` column for the 41 collisions was copied from the digest (title truncated to 110 characters, year from the registry record).

## Web searches (25, all standard mode, exact title in quotes)
1. "Interfacial resistance and dendrite growth in argyrodite-type halide solid electrolytes" (vibe_007): only generic sulfide-argyrodite papers; no such title.
2. "Anion sublattice disorder and ionic transport in lithium halide argyrodites" (vibe_008): related simulation papers, no such title.
3. "Block preconditioners for coupled flow and deformation in heterogeneous poroelastic media" (vibe_013): Haga et al. and Chen et al. papers, different titles.
4. "Robust multigrid preconditioning for saddle-point systems arising in Biot consolidation" (vibe_014): Lee/Mardal/Winther, Boon et al., Adler et al.; none match.
5. "Field measurements of pedestrian-induced vibration in a slender steel footbridge" (vibe_020): Footbridge 2014 and Eeklo papers, different titles.
6. "Protein stabilization during repeated drying of a montane moss" (codex_024): Dhindsa/Bewley and Bryum papers, no match.
7. "Evidentiality and mirativity in a Tibeto-Burman language of eastern Nepal" (vibe_029): only Grunow-Harsta "...in Magar" (2007, different title, author, language).
8. "Evidential Systems in Tibeto-Burman: A Comparative Study" Zhou (vibe_030): only Aikhenvald/LaPolla 2007 and Gawne & Hill "Evidential Systems in Tibetan Languages"; not the same.
9. "Seroprevalence of leptospirosis among residents of an urban informal settlement" (vibe_031): French Guiana 2025, Guatemala 2013, Salvador 2024 etc.; none match.
10. "Blue carbon stocks and sediment accumulation in a Mediterranean seagrass meadow" (vibe_038): Corsica / Tunisia Posidonia papers, different titles.
11. "Non-destructive analysis of iron-gall ink on historical manuscripts" (vibe_040): several non-destructive iron-gall papers (Hahn 2010, Corregidor 2019, Caterino 2025), none with this title or these authors.
12. "Dislocation climb and creep in single-phase high-entropy alloys" (vibe_028): creep papers on CoCrFeMnNi etc., no such title.
13. "Tone Domains and Syllable Chains in Hmong-Mien Speech" (codex_030): nothing.
14. "Plots and Possession: Reading Provincial Ottoman Cadastral Maps" (codex_025): nothing (MESA abstract, Konya project are different).
15. "Ceramics and Exchange on the Medieval Swahili Coast" (vibe_026): nothing; related papers only.
16. "Weight Standards and Mint Practice in Kushan Copper Coinage" (vibe_006): nothing; Cribb's "Kushan Copper Coinage: Gaining and Losing Control" is a different work.
17. "Tuned mass damping of lateral and torsional vibrations in a slender cable-stayed footbridge" (vibe_019): nothing.
18. "Tropical compactifications of tree space and the geometry of phylogenetic inference" (vibe_033): only Monod/Lin/Yoshida tropical tree-space papers (arXiv 1805.12400), different title.
19. "Letter Forms at the Edge of the Page" Icelandic scribal practice (codex_005): nothing.
20. "Morphological segmentation with shared stem priors for two under-resourced Uralic languages" (codex_010): only Gronroos et al. papers, different titles.
21. "Rehydration timing and chloroplast repair in desiccation-tolerant bryophyte mats" (codex_023): Bryum argenteum papers, different titles.
22. "A revised generic classification of troglobitic springtails from the western Mediterranean karst" (vibe_003): nothing.
23. "Radar echoes of nocturnal migration over a coastal strait: density, heading and wind drift" (vibe_016): nothing.
24. "Creep resistance of refractory high-entropy alloys at elevated temperature" Sokolov Kuznetsova (vibe_027): nothing.
25. "Antibiotic-resistance profiles along the inlet-to-outlet gradient of aquaculture ponds" (codex_032): nothing.

The search tool is a summarising wrapper, not raw Google, so "found nothing" is weaker than an exact-phrase hit count. Combined with the registry evidence I consider it sufficient. Not searched individually: the remaining 55 entries, all with best similarity below 0.60 and specific (non-generic) titles, or collisions where the identifier is already proven to be another work.

## matches_real_work / unsure
None. Closest similarities above 0.60 were all checked and are related-topic papers with different titles: vibe_007 (0.69, "Interfacial Electronic Properties Dictate Li Dendrite Growth..."), vibe_008 (0.66, "Exploring the Anion Site Disorder Kinetics in Lithium Argyrodites"), vibe_013 (0.69), vibe_014 (0.70), vibe_020 (0.72, Li 2015), vibe_028 (0.67), vibe_029/030 (0.66/0.64, Gawne 2021 "Reported Evidentiality..."), vibe_031 (0.67), vibe_038 (0.76), vibe_040 (0.65), codex_024 (0.68, Pikal 2004 freeze-drying), codex_006/vibe_019/vibe_027/vibe_036/vibe_037 and others in the 0.60 to 0.66 range. In each case the title differs by more than a word or two, and the first author and venue differ.

## Real-name flags
No `real name:` flag. Weak observations only, none confident enough to flag:
- vibe_026 "Chami, Fatuma A.": the surname matches Felix A. Chami, a real archaeologist of the Swahili coast (ceramics, Tanzania). Different given name, so not the same string, but a reader could assume a link. Consider renaming.
- codex_026 co-author "Claude Perrault": the 17th-century French architect; a historical figure, not a living person, but implausible here.
- vibe_013 "Dmitri Petrov": a real evolutionary biologist, unrelated field (numerical analysis); coincidence of a common name.
- vibe_009 "Kathrin Meyer" on whistled speech: Julien Meyer is the real whistled-speech researcher; given name differs.
My knowledge of all author names is limited, so the other names are unchecked beyond this.

## Other things for the dispatcher
- Several entries cite real, specific venues with plausible years; some venue/type mismatches exist: vibe_010 is an @article for an ICPhS proceedings paper; vibe_038 is an @article for a symposium proceedings; vibe_030's "De Gruyter Mouton, 2019" and codex_030's "De Gruyter Mouton, 2006" are real publishers, so a reader could believe them real. vibe_020 cites a "8th International Conference on Structural Dynamics", which is a real-sounding series (EURODYN); vibe_027 cites a "12th International Symposium on Superalloys" (real series is every 4 years, 2020 was the 14th); codex_020 cites "16th European Conference on Earthquake Engineering" (it was 2018, so plausible).
- All 41 collisions rest on real DOIs / arXiv ids / PMIDs of unrelated papers. Publishing these entries with their identifiers will make a resolver return an unrelated paper, which is the intended benchmark trap, but the README should say so.
- Author lists look like invented names; no obvious real-author collision found.
