# ScholarOS 评测集：编造条目抽查（10 条）

这 10 条是从 80 条模型编造的参考文献里按固定种子抽的（Codex 5 条、vibe 5 条）。请确认它们确实不是真实存在的文献。每条下面是脚本查到的情况和复核 agent 的结论；"去搜"的链接只带这条的标题。

看完后告诉我哪几条有问题即可（例如"第 3 条其实是真的"）；都没问题就说"抽查通过"。

## 1. `fab_codex_012`（Codex 写的，带 DOI）

```bibtex
@article{fab_codex_012,
  author = {Martha Aluko and Peter Wrenford and Devika Saha},
  title = {Travel costs and attendance gains from rural retinal image triage},
  journal = {Journal of Health Economics},
  volume = {82},
  pages = {102581},
  year = {2022},
  doi = {10.1016/j.jhealeco.2022.102581}
}
```

- 标识符：这个标识符存在，属于另一篇文献（10.1016/j.jhealeco.2022.102581）
  - 它实际属于：The impact of the COVID-19 pandemic and policy response on health care utilization: Evidence from county-level medical claims and cellphone data（Crossref，2022）
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.47：The International Gains from Declining Transport Costs（Lashkaripour，2015，Crossref）
  - 相似度 0.45：Achievement Gains from Attendance at Selective High Schools（Houng，2018，Crossref）
  - 相似度 0.43：Figure 1.17. Gains from different trade facilitation measures (% reduction in trade costs)（作者不详，年份不详，Crossref）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文，但标识符撞上了一篇真文献。复核备注原文：doi exists but belongs to a different work; closest title 0.471, different title and topic.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Travel%20costs%20and%20attendance%20gains%20from%20rural%20retinal%20image%20triage%22)

## 2. `fab_codex_040`（Codex 写的，带 DOI）

```bibtex
@article{fab_codex_040,
  author = {Ariadne Papadaki and Luc Moreau and Selma Gruber},
  title = {Pore-water renewal and layered corrosion of bronze artefacts in marine silt},
  journal = {Corrosion Science},
  volume = {197},
  pages = {110066},
  year = {2022},
  doi = {10.1016/j.corsci.2022.110066}
}
```

- 标识符：数据源里没有这个标识符（10.1016/j.corsci.2022.110066）
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.58：Corrosion of archaeological bronze artefacts in acidic soil（Tronner，1995，Crossref）
  - 相似度 0.51：Photo-induced passivation: A new corrosion mitigation strategy for bronze artefacts（Wu，2024，Crossref）
  - 相似度 0.44：Simulation of corrosion processes of buried archaeological bronze artefacts（ANGELINI，2007，Crossref）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文。复核备注原文：identifier not registered; closest title 0.582, different title.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Pore-water%20renewal%20and%20layered%20corrosion%20of%20bronze%20artefacts%20in%20marine%20silt%22)

## 3. `fab_codex_038`（Codex 写的，无标识符）

```bibtex
@article{fab_codex_038,
  author = {Nadia Birk and Petra Almquist and Luca Ferretti},
  title = {Late-season fly visitation and network redundancy in an alpine grassland},
  journal = {Oecologia},
  volume = {179},
  number = {2},
  pages = {531--542},
  year = {2015}
}
```

- 标识符：没有标识符
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.44：Influence of Climate, Time of Day and Season, and Flower Density on Insect Flower Visitation in Alpine Norway（Totland，1994，Crossref）
  - 相似度 0.44：Influence of Climate, Time of Day and Season, and Flower Density on Insect Flower Visitation in Alpine Norway（Totland，1994，Crossref）
  - 相似度 0.41：Nectar chemistry reflects pollination strategies in alpine plant communities（Roberto Rebollo，2026，OpenAlex）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文。复核备注原文：no identifier; closest title 0.436, different title.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Late-season%20fly%20visitation%20and%20network%20redundancy%20in%20an%20alpine%20grassland%22)

## 4. `fab_codex_002`（Codex 写的，无标识符）

```bibtex
@article{fab_codex_002,
  author = {Maija Rautio and Soren Haldvik},
  title = {Counting winter couplets across the inlet basins of Lake Vardalen},
  journal = {Journal of Paleolimnology},
  volume = {52},
  number = {3},
  pages = {241--258},
  year = {2014}
}
```

- 标识符：没有标识符
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.39：Voyage across Lake St. Clair（作者不详，2011，Crossref）
  - 相似度 0.35：The dominant role of sunlight in degrading winter dissolved organic matter from a thermokarst lake in a subarctic peatland（Mazoyer，2022，Crossref）
  - 相似度 0.35：The dominant role of sunlight in degrading winter dissolved organic matter from a thermokarst lake in a subarctic peatland（Mazoyer，2022，Crossref）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文。复核备注原文：no identifier; closest title 0.391, different title.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Counting%20winter%20couplets%20across%20the%20inlet%20basins%20of%20Lake%20Vardalen%22)

## 5. `fab_codex_013`（Codex 写的，带 arXiv 编号）

```bibtex
@article{fab_codex_013,
  author = {Ruben Stenfeld and Marieke Olsson},
  title = {Ritz value drift under oblique projection of sparse non-normal operators},
  journal = {SIAM Journal on Matrix Analysis and Applications},
  volume = {40},
  number = {3},
  pages = {1094--1118},
  year = {2019},
  eprint = {1809.06421},
  archivePrefix = {arXiv}
}
```

- 标识符：这个标识符存在，属于另一篇文献（1809.06421）
  - 它实际属于：A Flexible Design for Funding Public Goods（arXiv，2018）
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.53：PROJECTION OPERATORS AND NORMAL FORMS（作者不详，1972，Crossref）
  - 相似度 0.46：Solvability of some boundary value problems involving p-Laplacian and non-autonomous differential operators（Petrini，2019，Crossref）
  - 相似度 0.43：On the non-Hermitian FEAST algorithms with oblique projection for eigenvalue problems（Yin，2019，Crossref）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文，但标识符撞上了一篇真文献。复核备注原文：arxiv exists but belongs to a different work; closest title 0.532, different title and topic.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Ritz%20value%20drift%20under%20oblique%20projection%20of%20sparse%20non-normal%20operators%22)

## 6. `fab_vibe_010`（vibe 写的，带 DOI）

```bibtex
@article{fab_vibe_010,
  author = {Ozturk, Selin and Demirci, Hakan and Yildirim, Ayse},
  title = {Prosodic cues in whistled Turkish: an acoustic study of vowel height and stress},
  booktitle = {Proceedings of the 19th International Congress of Phonetic Sciences},
  year = {2019},
  pages = {2241--2245},
  doi = {10.21437/ICPhS.2019-2241}
}
```

- 标识符：数据源里没有这个标识符（10.21437/ICPhS.2019-2241）
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.56：Prosodic cues to emotion : perceptual and acoustic analyses（De Bodt，年份不详，Crossref）
  - 相似度 0.48：Perceiving whistled speech : a study of musicians' capacity for language processing（Anaïs Tran Ngoc，2023，OpenAlex）
  - 相似度 0.45：Domain-Initial Strengthening in Turkish: Acoustic Cues to Prosodic Hierarchy in Stop Consonants（Bodur，2021，Crossref）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文。复核备注原文：identifier not registered; closest title 0.563, different title.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Prosodic%20cues%20in%20whistled%20Turkish%3A%20an%20acoustic%20study%20of%20vowel%20height%20and%20stress%22)

## 7. `fab_vibe_021`（vibe 写的，带 DOI）

```bibtex
@article{fab_vibe_021,
  author = {Tashi, Sonam and Wangchuk, Karma and Dorji, Pema},
  title = {Ring-width chronologies of high-altitude juniper and their response to monsoon variability},
  journal = {Dendrochronologia},
  year = {2017},
  volume = {44},
  pages = {55--66},
  doi = {10.1016/j.dendro.2017.04.003}
}
```

- 标识符：这个标识符存在，属于另一篇文献（10.1016/j.dendro.2017.04.003）
  - 它实际属于：An empirical resampling method for determining optimal high-pass filters used in correlation-based tree-ring crossdating（Crossref，2017）
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.58：Tree-Ring Width Chronologies and Their Response to Climate in the Qinling Mountains, China（Wu，1994，Crossref）
  - 相似度 0.51：Tree-Ring Chronologies from Western Himalaya and Their Dendroclimatic Potential（Hemant P. Borgaonkar，1999，OpenAlex）
  - 相似度 0.48：Global surface temperature signals in pine ring‐width chronologies from southern monsoon Asia（Buckley，2005，Crossref）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文，但标识符撞上了一篇真文献。复核备注原文：doi exists but belongs to a different work; closest title 0.581, different title and topic.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Ring-width%20chronologies%20of%20high-altitude%20juniper%20and%20their%20response%20to%20monsoon%20variability%22)

## 8. `fab_vibe_022`（vibe 写的，无标识符）

```bibtex
@article{fab_vibe_022,
  author = {Bhatt, Jaya and Rawat, Deepak},
  title = {Temperature sensitivity of juniper growth at a timberline site in the western Himalaya},
  journal = {Tree-Ring Research},
  year = {2006},
  volume = {62},
  number = {2},
  pages = {91--103}
}
```

- 标识符：没有标识符
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.54：Spatial Distribution and Climatic Sensitivity of Juniper Forests in the Cold-Arid Ladakh, North-western Himalaya, India（Misra，2026，Crossref）
  - 相似度 0.53：Pastoralism in Timberline Forests of Western Himalaya（Singh，2023，Crossref）
  - 相似度 0.52：Temperature change along elevation and its effect on the alpine timberline tree growth in the southeast of the Tibetan Plateau（Baoxiong Chen，2018，OpenAlex）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文。复核备注原文：no identifier; closest title 0.542, different title.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Temperature%20sensitivity%20of%20juniper%20growth%20at%20a%20timberline%20site%20in%20the%20western%20Himalaya%22)

## 9. `fab_vibe_006`（vibe 写的，无标识符）

```bibtex
@book{fab_vibe_006,
  author = {Mukherjee, Ratnabali},
  title = {Weight Standards and Mint Practice in Kushan Copper Coinage},
  publisher = {Oxford University Press},
  address = {New Delhi},
  year = {2009}
}
```

- 标识符：没有标识符
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.51：Arab-Sasanian Copper Coinage（GYSELEN，2009，Crossref）
  - 相似度 0.43：Mint / minting (coinage)（作者不详，年份不详，Crossref）
  - 相似度 0.43：Weight Standards（作者不详，2011，Crossref）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文。复核备注原文：no identifier; closest title 0.506, different title. Web search for exact title found no such work.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Weight%20Standards%20and%20Mint%20Practice%20in%20Kushan%20Copper%20Coinage%22)

## 10. `fab_vibe_031`（vibe 写的，带 PMID）

```bibtex
@article{fab_vibe_031,
  author = {Ochieng, Beatrice and Mwangi, Peter and Otieno, Grace},
  title = {Seroprevalence of leptospirosis among residents of an urban informal settlement},
  journal = {PLOS Neglected Tropical Diseases},
  year = {2016},
  volume = {10},
  number = {5},
  pages = {e0004712},
  pmid = {27182904}
}
```

- 标识符：这个标识符存在，属于另一篇文献（27182904）
  - 它实际属于：-gnosis.（PubMed，2016）
- 按标题在 Crossref 和 OpenAlex 检索，最接近的 3 条：
  - 相似度 0.67：Infrastructure risk factors for leptospirosis transmission in urban informal settlements（Ana Maria Nascimento Silva，2026，OpenAlex）
  - 相似度 0.56：Efficient lighting uptake among the urban poor: evidence from a Kenyan informal settlement（Figueroa，2016，Crossref）
  - 相似度 0.54：Knowledge, attitudes and practices (KAP) regarding leptospirosis among residents of riverside settlements of Santa Fe, Argentina（Tamara Ricardo，2018，OpenAlex）
- 复核结论（Claude Sonnet (subagent, second reviewer)）：查无此文，但标识符撞上了一篇真文献。复核备注原文：pmid exists but belongs to a different work; closest title 0.671, different title and topic. Web search for exact title found no such work.
- 去搜：[Google Scholar](https://scholar.google.com/scholar?q=%22Seroprevalence%20of%20leptospirosis%20among%20residents%20of%20an%20urban%20informal%20settlement%22)
