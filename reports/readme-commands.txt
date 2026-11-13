# ScholarOS README & README.zh-CN Command Replay
Date: 2026-11-14

$ swift build
Building for debugging...
[Computing dependencies]
[1 / 40]
Build complete! (0.51秒)

$ ScholarOS outline "$WORK/paper.tex" --lang en
1 Introduction [paper.tex:3 · 5 words]
  1.1 Problem Statement [paper.tex:4 · 5 words]

$ ScholarOS outline "$WORK/paper.tex" --lang zh
1 Introduction [paper.tex:3 · 5 词]
  1.1 Problem Statement [paper.tex:4 · 5 词]

$ ScholarOS format-bib "$WORK/refs.bib" --style apa
LeCun, Y., Bengio, Y., & Hinton, G. (2015). Deep learning. Nature, 521, 436–444. https://doi.org/10.1038/nature14539

Wakefield, A. J. (1998). Ileal-lymphoid-nodular hyperplasia. The Lancet. https://doi.org/10.1016/s0140-6736(97)11096-0

$ ScholarOS format-bib "$WORK/refs.bib" --style ieee
[1] Y. LeCun, Y. Bengio, and G. Hinton, "Deep learning," Nature, vol. 521, pp. 436–444, 2015, doi: 10.1038/nature14539.

[2] A. J. Wakefield, "Ileal-lymphoid-nodular hyperplasia," The Lancet, 1998, doi: 10.1016/s0140-6736(97)11096-0.

$ ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --lang en
[ERROR] ERR_UNVERIFIED_CITATION paper.tex:5:12 - [ERR_UNVERIFIED_CITATION] Citation 'lecun2015deep' is UNVERIFIED ([UNVERIFIED] DOI '10.1038/nature14539' has valid ISO 26324 syntax; not checked against external registry (offline).). Citation Firewall blocks manuscript export until verified.
[HINT] LINT_UNCITED_BIB_ENTRY paper.tex:1:1 - Bibliography entry 'wakefield1998retracted' (Wakefield, 1998) is uncited in the manuscript.
[HINT] LINT_MISSING_NONBREAKING_TIE paper.tex:5:11 - Missing non-breaking tie '~' before '\cite' (prevents awkward TeX line breaks after 'work').

$ ScholarOS diagnostics "$WORK/paper.tex" --bib "$WORK/refs.bib" --lang zh
[ERROR] ERR_UNVERIFIED_CITATION paper.tex:5:12 - 引文防火墙提醒：@lecun2015deep 尚未通过外部注册库核查 (ERR_UNVERIFIED_CITATION)。
[HINT] LINT_UNCITED_BIB_ENTRY paper.tex:1:1 - 文献库条目 @wakefield1998retracted 尚未在手稿正文中被引用。
[HINT] LINT_MISSING_NONBREAKING_TIE paper.tex:5:11 - 交叉引用前建议使用不间断空格波浪号（如 Equation~\ref{...}）以防行尾断行。

$ ScholarOS verify-citations "$WORK/refs.bib" --offline --lang en || echo "expected_exit=$?"
Evaluated=2 Verified=0 Drift=0 NotFound=0 Retracted=1 Unverified=1
[UNVERIFIED] lecun2015deep: [UNVERIFIED] DOI '10.1038/nature14539' has valid ISO 26324 syntax; not checked against external registry (offline).
[RETRACTED] wakefield1998retracted: [RETRACTED] DOI '10.1016/s0140-6736(97)11096-0' matched built-in offline retracted list (内置名单，不完整).
expected_exit=1

$ ScholarOS verify-citations "$WORK/refs.bib" --offline --lang zh || echo "expected_exit=$?"
Evaluated=2 Verified=0 Drift=0 NotFound=0 Retracted=1 Unverified=1
[UNVERIFIED] lecun2015deep: DOI '10.1038/nature14539' 语法格式合法；离线模式下尚未向外部注册库核查。
[RETRACTED] wakefield1998retracted: 离线撤稿提示：DOI '10.1016/S0140-6736(97)11096-0' 命中内置撤稿名单（内置名单，不完整）。
expected_exit=1

$ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ScholarOS mcp
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"version":"1.0.0","name":"scholaros-mcp"}}}

$ Scripts/test.sh scope ScholarBibAndCSL
[test.sh] Running scoped tests: --filter (BibCSLAndFirewallTests)
◇ Test run started.
↳ Testing Library Version: 2403
↳ Target Platform: arm64e-apple-macos14.0
◇ Suite "BibTeX/RIS/NBIB Codecs, Deduplication, 5-Style CSL & Citation Firewall" started.
◇ Test "BibTeX @string macro expansion, # concatenation, and @preamble preservation" started.
✔ Test "BibTeX @string macro expansion, # concatenation, and @preamble preservation" passed after 0.001 seconds.
◇ Test "LaTeXTextCodec decodes European diacritics and protects uppercase acronyms on encode" started.
✔ Test "LaTeXTextCodec decodes European diacritics and protects uppercase acronyms on encode" passed after 0.001 seconds.
◇ Test "BibTeXAuthorParser handles corporate braces, von particles, Jr. suffixes, and ORCIDs" started.
✔ Test "BibTeXAuthorParser handles corporate braces, von particles, Jr. suffixes, and ORCIDs" passed after 0.001 seconds.
◇ Test "BibTeXCodec lossless document serialization round-trip and collision-free citeKey generation" started.
✔ Test "BibTeXCodec lossless document serialization round-trip and collision-free citeKey generation" passed after 0.001 seconds.
◇ Test "RISParser multi-record import/export round-trip and strict-mode syntax error enforcement" started.
✔ Test "RISParser multi-record import/export round-trip and strict-mode syntax error enforcement" passed after 0.001 seconds.
◇ Test "PubMedNBIBParser parses MEDLINE multi-line continuations, ORCIDs, and expands abbreviated page ranges" started.
✔ Test "PubMedNBIBParser parses MEDLINE multi-line continuations, ORCIDs, and expands abbreviated page ranges" passed after 0.001 seconds.
◇ Test "ReferenceIdentifierNormalizer canonicalizes DOIs, versioned arXiv IDs, PMIDs, and surnames" started.
✔ Test "ReferenceIdentifierNormalizer canonicalizes DOIs, versioned arXiv IDs, PMIDs, and surnames" passed after 0.001 seconds.
◇ Test "Classical Jaro, Jaro-Winkler prefix boost, and token Jaccard similarity bounds" started.
✔ Test "Classical Jaro, Jaro-Winkler prefix boost, and token Jaccard similarity bounds" passed after 0.001 seconds.
◇ Test "ReferenceDeduplicator merges arXiv preprint with camera-ready venue while keeping distinct DOIs separate" started.
✔ Test "ReferenceDeduplicator merges arXiv preprint with camera-ready venue while keeping distinct DOIs separate" passed after 0.001 seconds.
◇ Test "CSL APA 7th parenthetical, narrative, locator, and 2017a/2017b year suffix disambiguation" started.
✔ Test "CSL APA 7th parenthetical, narrative, locator, and 2017a/2017b year suffix disambiguation" passed after 0.002 seconds.
◇ Test "CSL IEEE numeric bracket range compression and order-of-appearance bibliography" started.
✔ Test "CSL IEEE numeric bracket range compression and order-of-appearance bibliography" passed after 0.001 seconds.
◇ Test "CSL ACM, Nature Unicode superscript, and Vancouver ISO-4 styles render distinct conventions" started.
✔ Test "CSL ACM, Nature Unicode superscript, and Vancouver ISO-4 styles render distinct conventions" passed after 0.001 seconds.
◇ Test "ScholarlyIdentifierValidator validates ISO DOI syntax and arXiv calendar/version constraints" started.
✔ Test "ScholarlyIdentifierValidator validates ISO DOI syntax and arXiv calendar/version constraints" passed after 0.001 seconds.
◇ Test "ScholarlyIdentifierValidator verifies PMID bounds, ORCID ISO 7064 Mod 11-2, and ISSN ISO 3297 checksums" started.
✔ Test "ScholarlyIdentifierValidator verifies PMID bounds, ORCID ISO 7064 Mod 11-2, and ISSN ISO 3297 checksums" passed after 0.001 seconds.
◇ Test "CitationVerificationFirewall offline evaluate assigns UNVERIFIED, RETRACTED, and NOT_FOUND honestly without claiming VERIFIED" started.
✔ Test "CitationVerificationFirewall offline evaluate assigns UNVERIFIED, RETRACTED, and NOT_FOUND honestly without claiming VERIFIED" passed after 0.001 seconds.
◇ Test "Firewall hard-blocks smith2025hallucinated, retracted DOIs, and unverified entries with ERR_UNVERIFIED_CITATION" started.
✔ Test "Firewall hard-blocks smith2025hallucinated, retracted DOIs, and unverified entries with ERR_UNVERIFIED_CITATION" passed after 0.001 seconds.
◇ Test "CitationVerificationFirewall.auditLibrary aggregates 5-class ledger counts and pass rate" started.
✔ Test "CitationVerificationFirewall.auditLibrary aggregates 5-class ledger counts and pass rate" passed after 0.001 seconds.
◇ Test "S2 regression: offline evaluate never returns VERIFIED even when DOI or arXiv syntax is valid" started.
✔ Test "S2 regression: offline evaluate never returns VERIFIED even when DOI or arXiv syntax is valid" passed after 0.001 seconds.
◇ Test "S6 regression: built-in retracted DOI list yields RETRACTED and explicitly notes incomplete built-in list" started.
✔ Test "S6 regression: built-in retracted DOI list yields RETRACTED and explicitly notes incomplete built-in list" passed after 0.001 seconds.
◇ Test "S19 regression: transport error, HTTP 429, and HTTP 500 in verifyAgainstPublicRegistries all return UNVERIFIED" started.
✔ Test "S19 regression: transport error, HTTP 429, and HTTP 500 in verifyAgainstPublicRegistries all return UNVERIFIED" passed after 0.001 seconds.
◇ Test "ZoteroSQLiteReadBridge summarizes, imports, and searches temporary synthetic Zotero SQLite database" started.
✔ Test "ZoteroSQLiteReadBridge summarizes, imports, and searches temporary synthetic Zotero SQLite database" passed after 0.008 seconds.
◇ Test "ZoteroSQLiteReadBridge filters by collection name and respects maxItemsLimit" started.
✔ Test "ZoteroSQLiteReadBridge filters by collection name and respects maxItemsLimit" passed after 0.005 seconds.
✔ Suite "BibTeX/RIS/NBIB Codecs, Deduplication, 5-Style CSL & Citation Firewall" passed after 0.024 seconds.
✔ Test run with 22 tests in 1 suite passed after 0.024 seconds.

README & README.zh-CN COMMAND REPLAY PASSED.
