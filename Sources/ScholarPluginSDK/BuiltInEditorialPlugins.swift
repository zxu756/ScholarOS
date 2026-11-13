import Foundation
import ScholarModels
import ScholarMarkupAST
import ScholarBibAndCSL

// MARK: - Built-In JavaScriptCore Editorial Plugin Catalog (`BuiltInEditorialPluginCatalog`)

/// Provides the four flagship production JavaScriptCore editorial & statistical rigor plugins shipped with ScholarOS.
public enum BuiltInEditorialPluginCatalog: Sendable {
    public static let overclaimingRhetoricDetectorID = "overclaiming-rhetoric-detector"
    public static let antiAIProseSanitizerID = "anti-ai-prose-sanitizer"
    public static let apaStatConsistencyCheckerID = "apa-stat-consistency-checker"
    public static let venueSubmissionGateID = "venue-submission-gate"

    /// Returns all four built-in `ScholarPluginManifest` definitions in deterministic execution order.
    public static var allPlugins: [ScholarPluginManifest] {
        [
            overclaimingRhetoricDetector,
            antiAIProseSanitizer,
            apaStatConsistencyChecker,
            venueSubmissionGate
        ]
    }

    /// Looks up a built-in plugin manifest by its canonical `id`.
    public static func plugin(withID id: String) -> ScholarPluginManifest? {
        allPlugins.first { $0.id == id }
    }

    // MARK: 1. Overclaiming & Causal Rhetoric Auditor

    public static let overclaimingRhetoricDetector = ScholarPluginManifest(
        id: overclaimingRhetoricDetectorID,
        name: "Overclaiming & Causal Rhetoric Auditor",
        version: "2.1.0",
        summary: "Detects absolutist empirical claims ('proves universally', '100% immune', 'eliminates all hallucinations', 'solves once and for all'), unhedged causal verbs on observational phrasing, and blanket superiority assertions while skipping comments and math spans.",
        capabilities: [.readManuscriptAST, .emitEditorialFindings, .suggestProseRewrite],
        isBuiltIn: true,
        isEnabled: true,
        scriptSource: overclaimingRhetoricScript
    )

    // MARK: 2. Anti-AI Academic Prose Sanitizer

    public static let antiAIProseSanitizer = ScholarPluginManifest(
        id: antiAIProseSanitizerID,
        name: "Anti-AI Academic Prose Sanitizer",
        version: "2.1.0",
        summary: "Flags high-signal LLM rhetorical tropes ('delve into', 'rich tapestry', 'testament to', 'pivotal role', 'underscores the importance', 'it is worth noting that'), formulaic negative parallelisms, participial filler tails, and stacked promotional adjectives.",
        capabilities: [.readManuscriptAST, .emitEditorialFindings, .suggestProseRewrite],
        isBuiltIn: true,
        isEnabled: true,
        scriptSource: antiAIProseSanitizerScript
    )

    // MARK: 3. APA 7th Statistical & p-Value Consistency Verifier

    public static let apaStatConsistencyChecker = ScholarPluginManifest(
        id: apaStatConsistencyCheckerID,
        name: "APA 7th Statistical & p-Value Consistency Verifier",
        version: "2.1.0",
        summary: "Parses reported t, F, chi-square, r, and z test statistics, recomputes exact p-values via native Lanczos/Lentz special functions, and flags p = 0.000, impossible probability/correlation bounds, and alpha = .05 decision-boundary contradictions.",
        capabilities: [.readManuscriptAST, .emitEditorialFindings, .suggestProseRewrite],
        isBuiltIn: true,
        isEnabled: true,
        scriptSource: apaStatConsistencyScript
    )

    // MARK: 4. Double-Blind & Camera-Ready Venue Gate

    public static let venueSubmissionGate = ScholarPluginManifest(
        id: venueSubmissionGateID,
        name: "Double-Blind & Camera-Ready Venue Gate",
        version: "2.1.0",
        summary: "Audits double-blind anonymization leaks (non-anonymous \\author, GitHub/personal URLs, \\thanks grant disclosures), >250-word abstracts, unverified or firewall-blocked cited keys, and \\caption floats missing \\label.",
        capabilities: [.readManuscriptAST, .readBibliography, .emitEditorialFindings, .suggestProseRewrite],
        isBuiltIn: true,
        isEnabled: true,
        scriptSource: venueSubmissionGateScript
    )

    // MARK: - Executable JavaScript Plugin Sources

    private static let overclaimingRhetoricScript = #"""
    (function () {
      "use strict";

      const ABSOLUTIST_RULES = [
        {
          id: "PROVES_UNIVERSALLY",
          pattern: /\b(proves\s+universally|universally\s+proves|definitively\s+proves|irrefutably\s+proves|unequivocally\s+proves)\b/gi,
          severity: "SUBMISSION_BLOCKER",
          category: "Empirical Overclaim",
          skipInTheorem: true,
          replacement: "provides strong empirical evidence across the evaluated benchmarks",
          rationale: "Empirical evaluations on finite benchmarks cannot establish universal mathematical proof; calibrate scope to the tested distributions and datasets."
        },
        {
          id: "IMMUNE_100_PERCENT",
          pattern: /\b(100\s*%\s*(?:immune|accurate|error-free|elimination(?:\s+of\s+all\s+\w+)?)|completely\s+immune\s+to|zero\s+possible\s+failure)\b/gi,
          severity: "SUBMISSION_BLOCKER",
          category: "Absolutist Certainty Claim",
          skipInTheorem: false,
          replacement: "substantially resilient within measurement precision",
          rationale: "Claiming 100% immunity or zero error rate without confidence intervals violates falsifiability and invites immediate reviewer rejection."
        },
        {
          id: "ELIMINATES_ALL_HALLUCINATIONS",
          pattern: /\b((?:completely\s+)?(?:eliminates|eradicates)\s+all\s+(?:scholarly\s+)?(?:hallucinations|errors|biases|failure\s+modes|confounders))\b/gi,
          severity: "SUBMISSION_BLOCKER",
          category: "Empirical Overclaim",
          skipInTheorem: false,
          replacement: "markedly reduces hallucination and error rates under benchmarked conditions",
          rationale: "Stochastic or heuristic pipelines rarely achieve total eradication of failure modes; state the observed reduction percentage and confidence interval instead."
        },
        {
          id: "SOLVES_ONCE_AND_FOR_ALL",
          pattern: /\b(solves\s+(?:[\w-]+\s+){0,3}once\s+and\s+for\s+all|permanently\s+solves|represents\s+the\s+final\s+word\s+on)\b/gi,
          severity: "SUBMISSION_BLOCKER",
          category: "Empirical Overclaim",
          skipInTheorem: false,
          replacement: "addresses a central bottleneck in",
          rationale: "Phrases such as 'solves once and for all' overstate scientific finality and disregard boundary conditions and future threat models."
        },
        {
          id: "UNDENIABLY_DEMONSTRATES",
          pattern: /\b(undeniably\s+(?:demonstrates|guarantees|establishes|shows)|indisputably\s+(?:demonstrates|proves|establishes)|beyond\s+any\s+shadow\s+of\s+doubt|without\s+exception)\b/gi,
          severity: "RIGOR_WARN",
          category: "Unhedged Epistemic Rhetoric",
          skipInTheorem: false,
          replacement: "consistently indicates across our experimental suite",
          rationale: "Rhetorical intensifiers ('undeniably', 'indisputably', 'without exception') substitute epistemic force for statistical uncertainty quantification."
        },
        {
          id: "BLANKET_SUPERIORITY",
          pattern: /\b(outperforms\s+all\s+existing\s+(?:methods|approaches|systems|baselines)|strictly\s+superior\s+in\s+all\s+settings|beats\s+every\s+conceivable\s+baseline)\b/gi,
          severity: "RIGOR_WARN",
          category: "Unbounded Superiority Claim",
          skipInTheorem: false,
          replacement: "outperforms the evaluated baselines on the benchmarked tasks",
          rationale: "Qualify comparative superiority claims by explicitly naming the evaluated baselines, datasets, and evaluation metrics."
        }
      ];

      const OBSERVATIONAL_CUES = /\b(observational|cross-sectional|retrospective|correlational|survey\s+responses|registry\s+data|non-randomized|self-reported|associated\s+with|correlates\s+with)\b/i;
      const UNHEDGED_CAUSAL_VERBS = /\b(directly\s+causes|causally\s+drives|causally\s+determines|unambiguously\s+causes|proves\s+that\s+[^.;]{1,40}\s+causes|leads\s+directly\s+to|guarantees\s+an?\s+increase\s+in)\b/i;
      const CAUSAL_HEDGES_OR_BOUNDS = /\b(95\s*%\s*CI|confidence\s+interval|credible\s+interval|randomized|instrumental\s+variable|difference-in-differences|propensity\s+score|may\s+contribute|is\s+consistent\s+with|suggests\s+a\s+potential)\b/i;

      function buildContextualRewrite(rawLine, matchedPhrase, replacementPhrase) {
        if (!rawLine || !matchedPhrase) return replacementPhrase;
        const escaped = matchedPhrase.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const latexTolerant = escaped.replace(/%/g, "\\\\?%").replace(/\s+/g, "\\s+");
        const rx = new RegExp(latexTolerant, "i");
        if (rx.test(rawLine)) {
          return rawLine.replace(rx, replacementPhrase).trim();
        }
        return replacementPhrase;
      }

      const files = scholar.listFiles();
      let totalFindings = 0;

      for (let fIdx = 0; fIdx < files.length; fIdx++) {
        const filePath = files[fIdx];
        const lines = scholar.getAnnotatedLines(filePath);

        for (let i = 0; i < lines.length; i++) {
          const ln = lines[i];
          if (ln.isComment || ln.inVerbatim || ln.inDisplayMath) continue;

          const prose = (ln.prose || "").trim();
          if (!prose) continue;

          // Pass 1: Absolutist & non-falsifiable quantifiers
          for (let r = 0; r < ABSOLUTIST_RULES.length; r++) {
            const rule = ABSOLUTIST_RULES[r];
            if (rule.skipInTheorem && ln.inTheorem) continue;

            rule.pattern.lastIndex = 0;
            let match;
            while ((match = rule.pattern.exec(prose)) !== null) {
              const phrase = match[0];
              const cleanExcerpt = ln.commentStripped.trim();
              scholar.emitFinding({
                severity: rule.severity,
                category: rule.category,
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: cleanExcerpt.length > 180 ? phrase : cleanExcerpt,
                explanation: rule.rationale + " Matched phrase: '" + phrase + "'.",
                suggestedRewrite: buildContextualRewrite(cleanExcerpt, phrase, rule.replacement)
              });
              totalFindings++;
            }
          }

          // Pass 2: Causal verbs applied to observational / correlational context without identification or CI bounds
          if (OBSERVATIONAL_CUES.test(prose) && UNHEDGED_CAUSAL_VERBS.test(prose) && !CAUSAL_HEDGES_OR_BOUNDS.test(prose)) {
            const causalMatch = UNHEDGED_CAUSAL_VERBS.exec(prose);
            const causalVerb = causalMatch ? causalMatch[0] : "causal verb";
            const cleanExcerpt = ln.commentStripped.trim();
            scholar.emitFinding({
              severity: "RIGOR_WARN",
              category: "Observational-Causal Conflation",
              filePath: filePath,
              line: ln.line,
              matchedExcerpt: cleanExcerpt,
              explanation: "Unhedged causal phrasing ('" + causalVerb + "') appears alongside observational/correlational framing without causal identification or confidence bounds (e.g., 95% CI).",
              suggestedRewrite: buildContextualRewrite(cleanExcerpt, causalVerb, "is positively associated with")
            });
            totalFindings++;
          }
        }
      }

      console.info("Overclaiming auditor scanned " + files.length + " file(s); emitted " + totalFindings + " finding(s).");
    })();
    """#

    private static let antiAIProseSanitizerScript = #"""
    (function () {
      "use strict";

      const LLM_TROPES = [
        {
          pattern: /\b(delve\s+into|delves\s+into|delving\s+into)\b/gi,
          severity: "STYLE",
          category: "AI Lexical Trope",
          replacementFor: function (m) {
            const lower = m.toLowerCase();
            if (lower.indexOf("delving") === 0) return "analyzing";
            if (lower.indexOf("delves") === 0) return "analyzes";
            return "examine";
          },
          why: "'delve into' exhibits >10x post-2023 LLM frequency inflation in scientific prose; prefer direct analytical verbs ('examine', 'analyze', 'investigate')."
        },
        {
          pattern: /\b((?:rich|intricate|complex|multifaceted)\s+tapestry\s+of|rich\s+tapestry)\b/gi,
          severity: "RIGOR_WARN",
          category: "Inflated AI Metaphor",
          replacementFor: function (m) {
            return /of$/i.test(m) ? "heterogeneous structure of" : "structured body of evidence";
          },
          why: "Figurative 'tapestry' metaphors obscure technical specificity in empirical writing."
        },
        {
          pattern: /\b(stands\s+as\s+a\s+testament\s+to|serves\s+as\s+a\s+testament\s+to|is\s+a\s+testament\s+to|testament\s+to)\b/gi,
          severity: "STYLE",
          category: "Promotional AI Phrase",
          replacementFor: function (m) {
            return /^(stands|serves|is)/i.test(m) ? "corroborates" : "evidence of";
          },
          why: "'testament to' introduces editorializing praise rather than falsifiable empirical support."
        },
        {
          pattern: /\b(plays?\s+a\s+pivotal\s+role\s+in|pivotal\s+role)\b/gi,
          severity: "STYLE",
          category: "AI Vague Importance",
          replacementFor: function (m) {
            if (/^plays\b/i.test(m)) return "governs";
            if (/^play\b/i.test(m)) return "govern";
            return "central mechanism";
          },
          why: "'pivotal role' asserts importance vaguely; specify the exact causal, algorithmic, or statistical mechanism."
        },
        {
          pattern: /\b(underscores\s+the\s+(?:critical\s+|vital\s+)?importance\s+of|underscores\s+the\s+importance|underscores\s+the\s+need\s+for)\b/gi,
          severity: "STYLE",
          category: "AI Discourse Cliché",
          replacementFor: function (m) {
            return /need\s+for$/i.test(m) ? "motivates" : "demonstrates the sensitivity to";
          },
          why: "'underscores the importance' is a high-frequency synthetic transition cliché; state the quantitative sensitivity directly."
        },
        {
          pattern: /\b(it\s+is\s+worth\s+noting\s+that|it\s+is\s+important\s+to\s+note\s+that|it\s+bears\s+mentioning\s+that|crucially,\s+it\s+should\s+be\s+noted\s+that)\s*/gi,
          severity: "STYLE",
          category: "Throat-Clearing Filler",
          replacementFor: function () { return ""; },
          why: "Meta-commentary throat-clearing delays the technical proposition; state the empirical observation directly."
        },
        {
          pattern: /\b(in\s+today'?s\s+rapidly\s+evolving\s+landscape|ever-evolving\s+landscape|rapidly\s+evolving\s+realm)\b/gi,
          severity: "RIGOR_WARN",
          category: "Synthetic Opening Cliché",
          replacementFor: function () { return "in recent systems literature"; },
          why: "'rapidly evolving landscape' is a hallmark LLM stock opening devoid of domain citations."
        },
        {
          pattern: /\b(harness(?:ing)?\s+the\s+power\s+of|unlock(?:ing)?\s+the\s+(?:full\s+)?potential\s+of|pave\s+the\s+way\s+for\s+a\s+new\s+era)\b/gi,
          severity: "STYLE",
          category: "Promotional Copywriting",
          replacementFor: function () { return "leveraging"; },
          why: "Marketing copywriting ('unlock the full potential', 'harness the power') undermines scholarly neutrality."
        }
      ];

      const NEGATIVE_PARALLELISM_RX = /\bnot\s+(?:merely|just|simply)\s+([^,.;]{3,65}),\s*but\s+(?:rather|instead|also\s+fundamentally|fundamentally)\s+([^.;]{3,85})/i;
      const PARTICIPIAL_TAIL_RX = /,\s*(?:thereby\s+)?(underscoring|highlighting|showcasing|illuminating|exemplifying)\s+(?:the\s+|its\s+|our\s+)?([^.;]{8,90})/i;
      const PROMOTIONAL_ADJECTIVES = /\b(groundbreaking|revolutionary|transformative|cutting-edge|unparalleled|seamless|synergistic|holistic|paradigm-shifting|game-changing|bespoke|unprecedented)\b/gi;
      const CONJUNCTIVE_OPENER_RX = /^(Furthermore|Moreover|Additionally|Consequently),\s+/;

      function applySpanRewrite(rawLine, targetPhrase, replacement) {
        const escaped = targetPhrase.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\s+/g, "\\s+");
        const rx = new RegExp(escaped, "i");
        if (!rx.test(rawLine)) return replacement || rawLine.trim();
        let updated = rawLine.replace(rx, replacement).replace(/\s{2,}/g, " ").trim();
        if (replacement === "" && updated.length > 0) {
          updated = updated.charAt(0).toUpperCase() + updated.slice(1);
        }
        return updated;
      }

      const files = scholar.listFiles();
      let emitted = 0;

      for (let f = 0; f < files.length; f++) {
        const filePath = files[f];
        const lines = scholar.getAnnotatedLines(filePath);
        let recentConjunctiveOpeners = [];

        for (let i = 0; i < lines.length; i++) {
          const ln = lines[i];
          if (ln.isComment || ln.inVerbatim || ln.inDisplayMath) continue;
          const prose = (ln.prose || "").trim();
          if (!prose) continue;
          const cleanRaw = ln.commentStripped.trim();

          // 1. Lexical tropes
          for (let t = 0; t < LLM_TROPES.length; t++) {
            const trope = LLM_TROPES[t];
            trope.pattern.lastIndex = 0;
            let m;
            while ((m = trope.pattern.exec(prose)) !== null) {
              const matched = m[0];
              const rep = trope.replacementFor(matched);
              scholar.emitFinding({
                severity: trope.severity,
                category: trope.category,
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: cleanRaw,
                explanation: trope.why,
                suggestedRewrite: applySpanRewrite(cleanRaw, matched, rep)
              });
              emitted++;
            }
          }

          // 2. Formulaic negative parallelisms ("not merely X, but rather Y")
          const negMatch = NEGATIVE_PARALLELISM_RX.exec(prose);
          if (negMatch) {
            const fullNeg = negMatch[0];
            const directY = negMatch[2].trim();
            scholar.emitFinding({
              severity: "STYLE",
              category: "Negative Parallelism Trope",
              filePath: filePath,
              line: ln.line,
              matchedExcerpt: fullNeg,
              explanation: "Formulaic contrast ('not merely X, but rather Y') is a pervasive LLM rhetorical tic; state the primary technical property directly.",
              suggestedRewrite: applySpanRewrite(cleanRaw, fullNeg, directY)
            });
            emitted++;
          }

          // 3. Superficial participial commentary tails
          const tailMatch = PARTICIPIAL_TAIL_RX.exec(prose);
          if (tailMatch) {
            scholar.emitFinding({
              severity: "STYLE",
              category: "Superficial Participial Tail",
              filePath: filePath,
              line: ln.line,
              matchedExcerpt: tailMatch[0].replace(/^,\s*/, ""),
              explanation: "Trailing '-ing' interpretive clauses ('" + tailMatch[1] + " ...') pad sentence endings with generic commentary; replace with a concrete metric or remove.",
              suggestedRewrite: cleanRaw.replace(PARTICIPIAL_TAIL_RX, "")
            });
            emitted++;
          }

          // 4. Stacked promotional adjectives (>= 3 in a single line/paragraph)
          PROMOTIONAL_ADJECTIVES.lastIndex = 0;
          const promoHits = [];
          let pm;
          while ((pm = PROMOTIONAL_ADJECTIVES.exec(prose)) !== null) {
            promoHits.push(pm[0]);
          }
          if (promoHits.length >= 3) {
            let stripped = cleanRaw;
            for (let k = 0; k < promoHits.length; k++) {
              const adjRx = new RegExp("\\b" + promoHits[k].replace(/[-]/g, "\\-") + "(?:,\\s*|\\s+and\\s+|\\s+)", "i");
              stripped = stripped.replace(adjRx, "");
            }
            scholar.emitFinding({
              severity: "RIGOR_WARN",
              category: "Stacked Promotional Adjectives",
              filePath: filePath,
              line: ln.line,
              matchedExcerpt: promoHits.join(", "),
              explanation: "Stacking " + promoHits.length + " promotional adjectives (" + promoHits.join(", ") + ") weakens technical credibility; substitute measurable system properties.",
              suggestedRewrite: stripped.replace(/\s{2,}/g, " ").trim()
            });
            emitted++;
          }

          // 5. Consecutive conjunctive openers
          const openerMatch = CONJUNCTIVE_OPENER_RX.exec(prose);
          if (openerMatch) {
            recentConjunctiveOpeners.push({ line: ln.line, word: openerMatch[1], raw: cleanRaw });
            recentConjunctiveOpeners = recentConjunctiveOpeners.filter(function (item) {
              return (ln.line - item.line) <= 14;
            });
            if (recentConjunctiveOpeners.length >= 3) {
              scholar.emitFinding({
                severity: "NOTE",
                category: "Repetitive Discourse Signposting",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: cleanRaw,
                explanation: "Three or more closely spaced sentences open with mechanical signposts ('Furthermore,', 'Moreover,', 'Additionally,'); vary transitions or let topic sentences carry logical progression.",
                suggestedRewrite: cleanRaw.replace(CONJUNCTIVE_OPENER_RX, "")
              });
              recentConjunctiveOpeners = [];
              emitted++;
            }
          }
        }
      }

      console.info("Anti-AI prose sanitizer finished across " + files.length + " file(s); emitted " + emitted + " finding(s).");
    })();
    """#

    private static let apaStatConsistencyScript = #"""
    (function () {
      "use strict";

      function normalizeStatText(raw) {
        return raw
          .replace(/\\(?:,|;|!|quad|qquad)/g, " ")
          .replace(/\\text\{([^}]*)\}/g, "$1")
          .replace(/\\mathrm\{([^}]*)\}/g, "$1")
          .replace(/\\le\b|\\leq\b/g, "<")
          .replace(/\\ge\b|\\geq\b/g, ">")
          .replace(/\$/g, "")
          .replace(/~/g, " ")
          .replace(/\s+/g, " ")
          .trim();
      }

      function formatAPAPValue(p) {
        if (!isFinite(p) || isNaN(p)) return "p = NaN";
        if (p < 0.001) return "p < .001";
        if (p >= 0.9995) return "p > .999";
        const fixed = p.toFixed(3);
        return "p = " + fixed.replace(/^0/, "");
      }

      function evaluatePValueConsistency(params) {
        const label = params.label;
        const exactP = params.exactP;
        const op = params.op;
        const reportedP = params.reportedP;
        const reportedRaw = params.reportedRaw;
        const fullMatch = params.fullMatch;
        const filePath = params.filePath;
        const line = params.line;

        if (!isFinite(reportedP) || reportedP < 0.0 || reportedP > 1.0) {
          scholar.emitFinding({
            severity: "SUBMISSION_BLOCKER",
            category: "Impossible p-Value Bound",
            filePath: filePath,
            line: line,
            matchedExcerpt: fullMatch,
            explanation: "Reported probability '" + reportedRaw + "' in " + label + " lies outside [0, 1]. Exact recomputed tail probability is " + formatAPAPValue(exactP) + ".",
            suggestedRewrite: fullMatch.replace(/p\s*[=<>≤≥]\s*[+-]?\d*\.?\d+/i, formatAPAPValue(exactP))
          });
          return true;
        }

        if (op === "=" && /^0?\.0+$/.test(reportedRaw.trim())) {
          scholar.emitFinding({
            severity: "RIGOR_WARN",
            category: "APA 7th Zero p-Value Violation",
            filePath: filePath,
            line: line,
            matchedExcerpt: fullMatch,
            explanation: "APA 7th §6.36 prohibits reporting 'p = " + reportedRaw + "' because continuous test distributions have strictly positive tail density. Exact recomputed value: " + formatAPAPValue(exactP) + ".",
            suggestedRewrite: fullMatch.replace(/p\s*=\s*0?\.0+/i, formatAPAPValue(exactP))
          });
          return true;
        }

        if (!isFinite(exactP) || isNaN(exactP)) {
          return false;
        }

        const alpha = 0.05;
        const claimedSignificant =
          (op === "=" && reportedP < alpha) ||
          ((op === "<" || op === "≤") && reportedP <= alpha);
        const claimedNonSignificant =
          (op === "=" && reportedP >= alpha) ||
          ((op === ">" || op === "≥") && reportedP >= alpha);

        // 1. Gross alpha = .05 decision-boundary contradiction
        if (claimedSignificant && exactP >= alpha + 0.002) {
          scholar.emitFinding({
            severity: "SUBMISSION_BLOCKER",
            category: "Statistical Decision-Boundary Error",
            filePath: filePath,
            line: line,
            matchedExcerpt: fullMatch,
            explanation: "Gross decision-boundary inconsistency in " + label + ": reported as statistically significant at alpha = .05 (p " + op + " " + reportedRaw + "), whereas exact recomputed p-value is non-significant (" + formatAPAPValue(exactP) + ", exact = " + exactP.toFixed(4) + ").",
            suggestedRewrite: fullMatch.replace(/p\s*[=<>≤≥]\s*[+-]?\d*\.?\d+/i, formatAPAPValue(exactP))
          });
          return true;
        }

        if (claimedNonSignificant && exactP < alpha - 0.005) {
          scholar.emitFinding({
            severity: "SUBMISSION_BLOCKER",
            category: "Statistical Decision-Boundary Error",
            filePath: filePath,
            line: line,
            matchedExcerpt: fullMatch,
            explanation: "Gross decision-boundary inconsistency in " + label + ": reported as non-significant (p " + op + " " + reportedRaw + "), whereas exact recomputed p-value is statistically significant (" + formatAPAPValue(exactP) + ", exact = " + exactP.toFixed(4) + ").",
            suggestedRewrite: fullMatch.replace(/p\s*[=<>≤≥]\s*[+-]?\d*\.?\d+/i, formatAPAPValue(exactP))
          });
          return true;
        }

        // 2. Numeric or inequality discrepancy within same decision region
        const absDiff = Math.abs(reportedP - exactP);
        if (op === "=" && absDiff > 0.015) {
          scholar.emitFinding({
            severity: "RIGOR_WARN",
            category: "p-Value Recomputation Discrepancy",
            filePath: filePath,
            line: line,
            matchedExcerpt: fullMatch,
            explanation: "Reported p-value (p = " + reportedRaw + ") for " + label + " deviates by " + absDiff.toFixed(3) + " from exact recomputed " + formatAPAPValue(exactP) + " (" + exactP.toFixed(4) + "). Verify degrees of freedom or rounding.",
            suggestedRewrite: fullMatch.replace(/p\s*=\s*[+-]?\d*\.?\d+/i, formatAPAPValue(exactP))
          });
          return true;
        }

        if ((op === "<" || op === "≤") && exactP > reportedP + 0.003) {
          scholar.emitFinding({
            severity: "RIGOR_WARN",
            category: "Invalid p-Value Inequality",
            filePath: filePath,
            line: line,
            matchedExcerpt: fullMatch,
            explanation: "Reported bound 'p < " + reportedRaw + "' for " + label + " is violated by exact recomputed p = " + exactP.toFixed(4) + ".",
            suggestedRewrite: fullMatch.replace(/p\s*[<≤]\s*[+-]?\d*\.?\d+/i, formatAPAPValue(exactP))
          });
          return true;
        }

        return false;
      }

      const T_TEST_RX = /\bt\s*\(\s*(\d+(?:\.\d+)?)\s*\)\s*=\s*([+-]?\d+(?:\.\d+)?)\s*,\s*p\s*([=<>≤≥])\s*([+-]?\d*\.?\d+)/gi;
      const F_TEST_RX = /\bF\s*\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*\)\s*=\s*([+-]?\d+(?:\.\d+)?)\s*,\s*p\s*([=<>≤≥])\s*([+-]?\d*\.?\d+)/gi;
      const CHI_TEST_RX = /(?:\\chi\^2|chi\^2|χ²|χ\^2)\s*\(\s*(\d+(?:\.\d+)?)(?:\s*,\s*N\s*=\s*\d+)?\s*\)\s*=\s*([+-]?\d+(?:\.\d+)?)\s*,\s*p\s*([=<>≤≥])\s*([+-]?\d*\.?\d+)/gi;
      const R_TEST_RX = /\br\s*\(\s*(\d+(?:\.\d+)?)\s*\)\s*=\s*([+-]?\d*\.?\d+)\s*,\s*p\s*([=<>≤≥])\s*([+-]?\d*\.?\d+)/gi;
      const Z_TEST_RX = /\bz\s*=\s*([+-]?\d+(?:\.\d+)?)\s*,\s*p\s*([=<>≤≥])\s*([+-]?\d*\.?\d+)/gi;

      const STANDALONE_P_RX = /\bp\s*([=<>≤≥])\s*([+-]?\d*\.?\d+)/gi;
      const STANDALONE_R_BOUND_RX = /\br(?:\s*\(\s*\d+(?:\.\d+)?\s*\))?\s*=\s*([+-]?\d+\.\d+)/gi;

      const files = scholar.listFiles();
      let auditedTests = 0;

      for (let f = 0; f < files.length; f++) {
        const filePath = files[f];
        const lines = scholar.getAnnotatedLines(filePath);

        for (let i = 0; i < lines.length; i++) {
          const ln = lines[i];
          if (ln.isComment || ln.inVerbatim) continue;
          const normalized = normalizeStatText(ln.commentStripped);
          if (!normalized) continue;

          const handledSpans = [];
          let m;

          // 1. Two-tailed Student's t-tests
          T_TEST_RX.lastIndex = 0;
          while ((m = T_TEST_RX.exec(normalized)) !== null) {
            auditedTests++;
            handledSpans.push([m.index, m.index + m[0].length]);
            const df = parseFloat(m[1]);
            const tVal = parseFloat(m[2]);
            const op = m[3];
            const pRaw = m[4];
            const pVal = parseFloat(pRaw);
            if (df <= 0) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Invalid Degrees of Freedom",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: m[0],
                explanation: "Student's t-test requires strictly positive degrees of freedom (df > 0)."
              });
              continue;
            }
            const exactP = scholar.computeTwoTailedTPValue(Math.abs(tVal), df);
            evaluatePValueConsistency({
              label: "t(" + m[1] + ") = " + m[2],
              exactP: exactP,
              op: op,
              reportedP: pVal,
              reportedRaw: pRaw,
              fullMatch: m[0],
              filePath: filePath,
              line: ln.line
            });
          }

          // 2. Fisher-Snedecor F-tests
          F_TEST_RX.lastIndex = 0;
          while ((m = F_TEST_RX.exec(normalized)) !== null) {
            auditedTests++;
            handledSpans.push([m.index, m.index + m[0].length]);
            const df1 = parseFloat(m[1]);
            const df2 = parseFloat(m[2]);
            const fVal = parseFloat(m[3]);
            const op = m[4];
            const pRaw = m[5];
            const pVal = parseFloat(pRaw);
            if (fVal < 0 || df1 <= 0 || df2 <= 0) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Impossible F-Statistic",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: m[0],
                explanation: "ANOVA F-ratios are ratios of non-negative mean squares (F >= 0) with df1 > 0, df2 > 0."
              });
              continue;
            }
            const exactP = scholar.computeFPValue(fVal, df1, df2);
            evaluatePValueConsistency({
              label: "F(" + m[1] + ", " + m[2] + ") = " + m[3],
              exactP: exactP,
              op: op,
              reportedP: pVal,
              reportedRaw: pRaw,
              fullMatch: m[0],
              filePath: filePath,
              line: ln.line
            });
          }

          // 3. Pearson chi-square tests
          CHI_TEST_RX.lastIndex = 0;
          while ((m = CHI_TEST_RX.exec(normalized)) !== null) {
            auditedTests++;
            handledSpans.push([m.index, m.index + m[0].length]);
            const df = parseFloat(m[1]);
            const chiVal = parseFloat(m[2]);
            const op = m[3];
            const pRaw = m[4];
            const pVal = parseFloat(pRaw);
            if (chiVal < 0 || df <= 0) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Impossible Chi-Square Statistic",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: m[0],
                explanation: "Pearson chi-square statistics must satisfy chi^2 >= 0 and df > 0."
              });
              continue;
            }
            const exactP = scholar.computeChiSquarePValue(chiVal, df);
            evaluatePValueConsistency({
              label: "chi^2(" + m[1] + ") = " + m[2],
              exactP: exactP,
              op: op,
              reportedP: pVal,
              reportedRaw: pRaw,
              fullMatch: m[0],
              filePath: filePath,
              line: ln.line
            });
          }

          // 4. Pearson r correlations with df
          R_TEST_RX.lastIndex = 0;
          while ((m = R_TEST_RX.exec(normalized)) !== null) {
            auditedTests++;
            handledSpans.push([m.index, m.index + m[0].length]);
            const df = parseFloat(m[1]);
            const rVal = parseFloat(m[2]);
            const op = m[3];
            const pRaw = m[4];
            const pVal = parseFloat(pRaw);
            if (Math.abs(rVal) > 1.0) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Out-of-Bounds Correlation",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: m[0],
                explanation: "Pearson correlation coefficient r = " + m[2] + " violates Cauchy-Schwarz bounds (|r| <= 1.0)."
              });
              continue;
            }
            const exactP = scholar.computePearsonRPValue(rVal, df);
            evaluatePValueConsistency({
              label: "r(" + m[1] + ") = " + m[2],
              exactP: exactP,
              op: op,
              reportedP: pVal,
              reportedRaw: pRaw,
              fullMatch: m[0],
              filePath: filePath,
              line: ln.line
            });
          }

          // 5. Standard normal z-tests
          Z_TEST_RX.lastIndex = 0;
          while ((m = Z_TEST_RX.exec(normalized)) !== null) {
            auditedTests++;
            handledSpans.push([m.index, m.index + m[0].length]);
            const zVal = parseFloat(m[1]);
            const op = m[2];
            const pRaw = m[3];
            const pVal = parseFloat(pRaw);
            const exactP = scholar.computeZPValue(Math.abs(zVal));
            evaluatePValueConsistency({
              label: "z = " + m[1],
              exactP: exactP,
              op: op,
              reportedP: pVal,
              reportedRaw: pRaw,
              fullMatch: m[0],
              filePath: filePath,
              line: ln.line
            });
          }

          // 6. Standalone p = 0.000 / p > 1.0 / p < 0.0 outside full tuples
          STANDALONE_P_RX.lastIndex = 0;
          while ((m = STANDALONE_P_RX.exec(normalized)) !== null) {
            const pos = m.index;
            const alreadyHandled = handledSpans.some(function (s) {
              return pos >= s[0] && pos < s[1];
            });
            if (alreadyHandled) continue;

            const op = m[1];
            const pRaw = m[2];
            const pVal = parseFloat(pRaw);
            if (!isFinite(pVal) || pVal < 0.0 || pVal > 1.0) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Impossible p-Value Bound",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: m[0],
                explanation: "Reported probability '" + m[0] + "' falls outside [0, 1]."
              });
            } else if (op === "=" && /^0?\.0+$/.test(pRaw.trim())) {
              scholar.emitFinding({
                severity: "RIGOR_WARN",
                category: "APA 7th Zero p-Value Violation",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: m[0],
                explanation: "APA 7th §6.36 mandates reporting 'p < .001' rather than '" + m[0] + "'.",
                suggestedRewrite: "p < .001"
              });
            } else if (/^0\.\d+$/.test(pRaw.trim())) {
              scholar.emitFinding({
                severity: "STYLE",
                category: "APA 7th Leading-Zero Style",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: m[0],
                explanation: "APA 7th omits leading zeros before the decimal point for statistics bounded by 1.0.",
                suggestedRewrite: "p " + op + " " + pRaw.trim().slice(1)
              });
            }
          }

          // 7. Standalone |r| > 1.0 without tuple p-value
          STANDALONE_R_BOUND_RX.lastIndex = 0;
          while ((m = STANDALONE_R_BOUND_RX.exec(normalized)) !== null) {
            const pos = m.index;
            const alreadyHandled = handledSpans.some(function (s) {
              return pos >= s[0] && pos < s[1];
            });
            if (alreadyHandled) continue;
            const rVal = parseFloat(m[1]);
            if (Math.abs(rVal) > 1.0) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Out-of-Bounds Correlation",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: m[0],
                explanation: "Reported correlation coefficient (" + m[0] + ") exceeds |r| <= 1.0."
              });
            }
          }
        }
      }

      console.info("APA 7th statistical verifier checked " + auditedTests + " hypothesis test tuple(s).");
    })();
    """#

    private static let venueSubmissionGateScript = #"""
    (function () {
      "use strict";

      const cfg = scholar.getConfig();
      const venueMode = cfg.venueMode || "doubleBlindSubmission";
      const isDoubleBlind = (venueMode === "doubleBlindSubmission");
      const maxAbstractWords = (typeof cfg.maxAbstractWords === "number" && cfg.maxAbstractWords > 0)
        ? cfg.maxAbstractWords
        : 250;

      const files = scholar.listFiles();

      // 1. Double-blind anonymization checks across all manuscript files
      if (isDoubleBlind) {
        const ANON_SAFE_AUTHOR_RX = /\b(anonymous|blind\s+review|under\s+review|paper\s*(?:id|#)|withheld)\b/i;
        const NON_ANON_URL_RX = /https?:\/\/(?!anonymous\.4open\.science)(?:www\.)?(github\.com\/[A-Za-z0-9_.-]+|gitlab\.com\/[A-Za-z0-9_.-]+|bitbucket\.org\/[A-Za-z0-9_.-]+|huggingface\.co\/[A-Za-z0-9_.-]+|[A-Za-z0-9.-]+\.edu\/~[A-Za-z0-9_.-]+)[^\s})>\]]*/gi;
        const THANKS_GRANT_RX = /\\thanks\s*\{([^}]*)\}/gi;
        const GRANT_DISCLOSURE_RX = /\b(NSF[-\s]?\d*|NIH\s+[A-Z0-9-]+|DARPA|ERC\s+(?:Starting|Consolidator|Advanced)|Grant\s+(?:No\.|Number|#)|supported\s+by\s+grant|funded\s+by)\b/i;
        const SELF_OWNERSHIP_RX = /\b((?:in|following|extending)\s+our\s+(?:previous|prior|earlier)\s+(?:work|paper|study|framework))\b/i;

        for (let f = 0; f < files.length; f++) {
          const filePath = files[f];
          const lines = scholar.getAnnotatedLines(filePath);
          let inAckSection = false;

          for (let i = 0; i < lines.length; i++) {
            const ln = lines[i];
            if (ln.isComment) continue;
            const clean = ln.commentStripped;

            // Track Acknowledgments section headers
            if (/\\(?:section|subsection|paragraph)\*?\{[^}]*acknowledg/i.test(clean)) {
              inAckSection = true;
            } else if (/\\(?:section|subsection)\*?\{/i.test(clean)) {
              inAckSection = false;
            }

            // 1a. \author{...} leak check
            const authorMatch = /\\author\s*\{([^}]*)\}/i.exec(clean);
            if (authorMatch) {
              const authorBody = authorMatch[1].trim();
              if (authorBody.length > 0 && !ANON_SAFE_AUTHOR_RX.test(authorBody)) {
                scholar.emitFinding({
                  severity: "SUBMISSION_BLOCKER",
                  category: "Double-Blind Anonymization Leak",
                  filePath: filePath,
                  line: ln.line,
                  matchedExcerpt: authorMatch[0],
                  explanation: "Explicit author identity ('" + authorBody + "') breaks double-blind peer review anonymity.",
                  suggestedRewrite: "\\author{Anonymous Submission}"
                });
              }
            }

            // 1b. Non-anonymized GitHub / GitLab / personal .edu URLs
            NON_ANON_URL_RX.lastIndex = 0;
            let urlMatch;
            while ((urlMatch = NON_ANON_URL_RX.exec(clean)) !== null) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Double-Blind Repository URL Leak",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: urlMatch[0],
                explanation: "Direct repository or personal academic URL ('" + urlMatch[0] + "') exposes author/institution identity during double-blind review.",
                suggestedRewrite: "https://anonymous.4open.science/r/anonymized-artifact"
              });
            }

            // 1c. \thanks{...} or Acknowledgments grant numbers
            THANKS_GRANT_RX.lastIndex = 0;
            let thanksMatch;
            while ((thanksMatch = THANKS_GRANT_RX.exec(clean)) !== null) {
              const body = thanksMatch[1].trim();
              if (body.length > 0 && !ANON_SAFE_AUTHOR_RX.test(body)) {
                scholar.emitFinding({
                  severity: "SUBMISSION_BLOCKER",
                  category: "Double-Blind Funding/Affiliation Leak",
                  filePath: filePath,
                  line: ln.line,
                  matchedExcerpt: thanksMatch[0],
                  explanation: "\\thanks footnote discloses affiliation or grant metadata ('" + body + "') prohibited in double-blind submissions.",
                  suggestedRewrite: "% \\thanks withheld for double-blind review"
                });
              }
            }

            if (inAckSection && GRANT_DISCLOSURE_RX.test(clean)) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Double-Blind Grant Number Leak",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: clean.trim(),
                explanation: "Grant numbers or funding agency acknowledgments in double-blind mode allow reviewer de-anonymization.",
                suggestedRewrite: "[Acknowledgments and funding disclosures withheld for double-blind review.]"
              });
            }

            // 1d. First-person prior-work ownership
            if (!ln.inVerbatim && !ln.inDisplayMath && SELF_OWNERSHIP_RX.test(ln.prose || clean)) {
              const own = SELF_OWNERSHIP_RX.exec(ln.prose || clean)[1];
              scholar.emitFinding({
                severity: "RIGOR_WARN",
                category: "Self-Identifying Citation Framing",
                filePath: filePath,
                line: ln.line,
                matchedExcerpt: clean.trim(),
                explanation: "First-person ownership of prior work ('" + own + "') weakens double-blind anonymity; cite own prior papers in the third person.",
                suggestedRewrite: clean.trim().replace(SELF_OWNERSHIP_RX, "Following prior work")
              });
            }
          }
        }
      }

      // 2. Abstract word-budget compliance (> maxAbstractWords, default 250)
      const metrics = scholar.getMetricsSummary();
      let abstractWords = (typeof metrics.abstractWordCount === "number") ? metrics.abstractWordCount : 0;
      let abstractStartFile = files[0] || "main.tex";
      let abstractStartLine = 1;

      // Locate \begin{abstract} line (and compute fallback word count if abstract formatted manually)
      let manualAbstractWords = 0;
      for (let f = 0; f < files.length; f++) {
        const lines = scholar.getAnnotatedLines(files[f]);
        for (let i = 0; i < lines.length; i++) {
          const ln = lines[i];
          if (/\\begin\{abstract\}/i.test(ln.commentStripped)) {
            abstractStartFile = files[f];
            abstractStartLine = ln.line;
          }
          if (ln.inAbstract && ln.prose) {
            const tokens = ln.prose.split(/\s+/).filter(function (w) { return w.length > 0; });
            manualAbstractWords += tokens.length;
          }
        }
      }
      if (abstractWords === 0 && manualAbstractWords > 0) {
        abstractWords = manualAbstractWords;
      }

      if (abstractWords > maxAbstractWords) {
        const excess = abstractWords - maxAbstractWords;
        scholar.emitFinding({
          severity: "RIGOR_WARN",
          category: "Abstract Word Budget Exceeded",
          filePath: abstractStartFile,
          line: abstractStartLine,
          matchedExcerpt: "\\begin{abstract} (" + abstractWords + " words)",
          explanation: "Abstract contains " + abstractWords + " words, exceeding the " + maxAbstractWords + "-word venue submission cap by " + excess + " word(s)."
        });
      }

      // 3. Citation Verification Firewall check on every cited key in manuscript
      const citations = scholar.getCitations();
      const checkedCiteSites = {};
      for (let c = 0; c < citations.length; c++) {
        const cite = citations[c];
        const siteKey = cite.filePath + ":" + cite.line + ":" + cite.citeKey;
        if (checkedCiteSites[siteKey]) continue;
        checkedCiteSites[siteKey] = true;

        const entry = scholar.getEntry(cite.citeKey);
        if (!entry) {
          scholar.emitFinding({
            severity: "SUBMISSION_BLOCKER",
            category: "Missing Bibliography Entry",
            filePath: cite.filePath,
            line: cite.line,
            matchedExcerpt: "\\" + cite.command + "{" + cite.citeKey + "}",
            explanation: "Cited key '" + cite.citeKey + "' is absent from the project bibliography and will render as '[?]' in camera-ready output."
          });
        } else if (entry.firewallClass === "BLOCKED_HALLUCINATED") {
          scholar.emitFinding({
            severity: "SUBMISSION_BLOCKER",
            category: "Citation Firewall Blocked Key",
            filePath: cite.filePath,
            line: cite.line,
            matchedExcerpt: "\\" + cite.command + "{" + cite.citeKey + "}",
            explanation: "Cited key '" + cite.citeKey + "' is classified as BLOCKED_HALLUCINATED by Citation Firewall (" + (entry.firewallAuditNote || "fabricated DOI or retracted work") + "). Remove or replace with a verified source."
          });
        } else if (entry.firewallClass === "UNVERIFIED_OFFLINE") {
          scholar.emitFinding({
            severity: "RIGOR_WARN",
            category: "Unverified Citation Key",
            filePath: cite.filePath,
            line: cite.line,
            matchedExcerpt: "\\" + cite.command + "{" + cite.citeKey + "}",
            explanation: "Cited key '" + cite.citeKey + "' has UNVERIFIED_OFFLINE status and has not been validated against Crossref, arXiv, or PubMed."
          });
        }
      }

      // 4. Floating figures & tables with \caption missing \label
      const FLOAT_ENVS = { "figure": "fig", "figure*": "fig", "table": "tab", "table*": "tab", "wrapfigure": "fig" };
      const envs = scholar.getEnvironments();
      for (let e = 0; e < envs.length; e++) {
        const env = envs[e];
        const prefix = FLOAT_ENVS[env.name];
        if (!prefix) continue;
        if (env.hasCaption && !env.hasLabel) {
          const excerpt = env.caption || ("\\begin{" + env.name + "} ... \\caption{...}");
          scholar.emitFinding({
            severity: "RIGOR_WARN",
            category: "Unlabeled Float Caption",
            filePath: env.filePath,
            line: env.startLine,
            matchedExcerpt: excerpt,
            explanation: "Floating '" + env.name + "' environment (lines " + env.startLine + "–" + env.endLine + ") defines a \\caption without a corresponding \\label{...}, preventing deterministic \\ref/\\cref cross-referencing.",
            suggestedRewrite: excerpt + "\\label{" + prefix + ":line" + env.startLine + "}"
          });
        }
      }

      console.info("Venue submission gate completed (" + venueMode + ", abstract=" + abstractWords + "w, citations=" + citations.length + ").");
    })();
    """#
}

// MARK: - Editorial Plugin Orchestrator & Summary (`EditorialPluginAuditRunner`)

/// Execution options governing multi-plugin editorial runs.
public struct EditorialAuditRunOptions: Sendable, Codable, Hashable {
    public var venueMode: EditorialVenueAuditMode
    public var maxAbstractWords: Int
    public var consoleRingBufferCapacity: Int
    public var maxFindingsPerPlugin: Int
    public var strictCapabilityEnforcement: Bool
    public var continueOnPluginError: Bool
    public var deduplicateIdenticalFindings: Bool

    public init(
        venueMode: EditorialVenueAuditMode = .doubleBlindSubmission,
        maxAbstractWords: Int = 250,
        consoleRingBufferCapacity: Int = 256,
        maxFindingsPerPlugin: Int = 500,
        strictCapabilityEnforcement: Bool = true,
        continueOnPluginError: Bool = false,
        deduplicateIdenticalFindings: Bool = true
    ) {
        self.venueMode = venueMode
        self.maxAbstractWords = maxAbstractWords
        self.consoleRingBufferCapacity = consoleRingBufferCapacity
        self.maxFindingsPerPlugin = maxFindingsPerPlugin
        self.strictCapabilityEnforcement = strictCapabilityEnforcement
        self.continueOnPluginError = continueOnPluginError
        self.deduplicateIdenticalFindings = deduplicateIdenticalFindings
    }

    public static let standard = EditorialAuditRunOptions()
}

/// Aggregated report returned by `EditorialPluginAuditRunner` across all enabled built-in and custom JS plugins.
public struct EditorialPluginRunSummary: Sendable, Codable, Hashable {
    public let findings: [EditorialAuditFinding]
    public let perPluginTimingsMs: [String: Double]
    public let logs: [PluginConsoleLogEntry]
    public let blockerCount: Int
    public let rigorWarningCount: Int
    public let styleSuggestionCount: Int
    public let noteCount: Int
    public let executedPluginIDs: [String]
    public let skippedDisabledPluginIDs: [String]
    public let pluginErrors: [String: String]
    public let totalElapsedMs: Double
    public let canSubmitCameraReady: Bool

    public init(
        findings: [EditorialAuditFinding],
        perPluginTimingsMs: [String: Double],
        logs: [PluginConsoleLogEntry],
        executedPluginIDs: [String] = [],
        skippedDisabledPluginIDs: [String] = [],
        pluginErrors: [String: String] = [:],
        totalElapsedMs: Double = 0.0
    ) {
        self.findings = findings
        self.perPluginTimingsMs = perPluginTimingsMs
        self.logs = logs
        self.executedPluginIDs = executedPluginIDs
        self.skippedDisabledPluginIDs = skippedDisabledPluginIDs
        self.pluginErrors = pluginErrors
        self.totalElapsedMs = totalElapsedMs

        var blockers = 0
        var warnings = 0
        var styles = 0
        var notes = 0
        for item in findings {
            switch item.severity {
            case .submissionBlocker: blockers += 1
            case .rigorWarning: warnings += 1
            case .styleSuggestion: styles += 1
            case .note: notes += 1
            }
        }
        self.blockerCount = blockers
        self.rigorWarningCount = warnings
        self.styleSuggestionCount = styles
        self.noteCount = notes
        self.canSubmitCameraReady = (blockers == 0 && pluginErrors.isEmpty)
    }

    public var formattedLogLines: [String] {
        logs.map(\.formattedLine)
    }
}

/// Orchestrates running enabled built-in and user custom JavaScriptCore editorial plugins over a manuscript workspace
/// and `[BibliographyEntry]` collection, producing deterministic findings, per-plugin timings, and camera-ready gate verdicts.
public struct EditorialPluginAuditRunner: Sendable {
    public var options: EditorialAuditRunOptions

    public init(options: EditorialAuditRunOptions = .standard) {
        self.options = options
    }

    /// Runs enabled editorial plugins against a single raw manuscript string and `[BibliographyEntry]` array.
    public func run(
        manuscriptSource: String,
        filePath: String = "main.tex",
        bibliography: [BibliographyEntry] = [],
        plugins: [ScholarPluginManifest]? = nil,
        additionalCustomPlugins: [ScholarPluginManifest] = []
    ) throws -> EditorialPluginRunSummary {
        try run(
            files: [filePath: manuscriptSource],
            primaryFilePath: filePath,
            bibliography: bibliography,
            plugins: plugins,
            additionalCustomPlugins: additionalCustomPlugins
        )
    }

    /// Runs enabled editorial plugins against a multi-file manuscript dictionary and `[BibliographyEntry]` array.
    public func run(
        files: [String: String],
        primaryFilePath: String = "main.tex",
        bibliography: [BibliographyEntry] = [],
        plugins: [ScholarPluginManifest]? = nil,
        additionalCustomPlugins: [ScholarPluginManifest] = [],
        perPluginConfigJSON: [String: String] = [:]
    ) throws -> EditorialPluginRunSummary {
        let suiteStartNanos = DispatchTime.now().uptimeNanoseconds

        let workspace = PreparedEditorialWorkspace(
            files: files,
            primaryFilePath: primaryFilePath,
            bibliography: bibliography
        )

        let baseList = plugins ?? BuiltInEditorialPluginCatalog.allPlugins
        var combinedManifests = baseList
        let existingIDs = Set(baseList.map(\.id))
        for custom in additionalCustomPlugins where !existingIDs.contains(custom.id) {
            combinedManifests.append(custom)
        }

        var allFindings: [EditorialAuditFinding] = []
        var timings: [String: Double] = [:]
        var aggregatedLogs: [PluginConsoleLogEntry] = []
        var executedIDs: [String] = []
        var skippedIDs: [String] = []
        var pluginErrors: [String: String] = [:]

        for manifest in combinedManifests {
            guard manifest.isEnabled else {
                skippedIDs.append(manifest.id)
                continue
            }

            let sandboxConfig = EditorialSandboxConfiguration(
                consoleRingBufferCapacity: options.consoleRingBufferCapacity,
                maxFindingsPerPlugin: options.maxFindingsPerPlugin,
                venueMode: options.venueMode,
                maxAbstractWords: options.maxAbstractWords,
                strictCapabilityEnforcement: options.strictCapabilityEnforcement,
                customConfigJSON: perPluginConfigJSON[manifest.id] ?? "{}"
            )
            let sandbox = EditorialJavaScriptSandbox(configuration: sandboxConfig)

            do {
                let singleResult = try sandbox.executePlugin(manifest, in: workspace)
                executedIDs.append(manifest.id)
                timings[manifest.id] = singleResult.executionTimeMs
                allFindings.append(contentsOf: singleResult.findings)
                aggregatedLogs.append(contentsOf: singleResult.logs)
            } catch {
                if options.continueOnPluginError {
                    pluginErrors[manifest.id] = error.localizedDescription
                } else {
                    throw error
                }
            }
        }

        let sortedFindings = Self.sortAndOptionallyDeduplicate(
            allFindings,
            deduplicate: options.deduplicateIdenticalFindings
        )
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - suiteStartNanos) / 1_000_000.0

        return EditorialPluginRunSummary(
            findings: sortedFindings,
            perPluginTimingsMs: timings,
            logs: aggregatedLogs,
            executedPluginIDs: executedIDs,
            skippedDisabledPluginIDs: skippedIDs,
            pluginErrors: pluginErrors,
            totalElapsedMs: totalMs
        )
    }

    /// Merges the four canonical built-in plugins with database-persisted `ScholarPluginManifest` records,
    /// preserving stored `isEnabled` flags and custom user plugins while ensuring all four flagship plugins are present.
    public static func mergeBuiltInAndStoredManifests(
        stored: [ScholarPluginManifest]
    ) -> [ScholarPluginManifest] {
        var storedByID: [String: ScholarPluginManifest] = [:]
        for item in stored {
            storedByID[item.id] = item
        }

        var merged: [ScholarPluginManifest] = []
        var includedIDs = Set<String>()

        for var builtIn in BuiltInEditorialPluginCatalog.allPlugins {
            if let existing = storedByID[builtIn.id] {
                builtIn.isEnabled = existing.isEnabled
            }
            merged.append(builtIn)
            includedIDs.insert(builtIn.id)
        }

        for item in stored where !includedIDs.contains(item.id) {
            merged.append(item)
            includedIDs.insert(item.id)
        }

        return merged
    }

    /// Applies an `EditorialAuditFinding.suggestedRewrite` onto line `finding.line` of `source`, returning the updated
    /// manuscript text when a deterministic line replacement is possible.
    public static func applySuggestedRewrite(
        _ finding: EditorialAuditFinding,
        to source: String
    ) -> String? {
        guard let rewrite = finding.suggestedRewrite,
              !rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let idx = finding.line - 1
        guard idx >= 0 && idx < lines.count else { return nil }

        let originalLine = lines[idx]
        let leadingWhitespace = String(originalLine.prefix { $0 == " " || $0 == "\t" })

        if !finding.matchedExcerpt.isEmpty,
           let excerptRange = originalLine.range(of: finding.matchedExcerpt) {
            lines[idx].replaceSubrange(excerptRange, with: rewrite)
        } else {
            lines[idx] = leadingWhitespace + rewrite
        }
        return lines.joined(separator: "\n")
    }

    private static func sortAndOptionallyDeduplicate(
        _ rawFindings: [EditorialAuditFinding],
        deduplicate: Bool
    ) -> [EditorialAuditFinding] {
        let sorted = rawFindings.sorted { lhs, rhs in
            if lhs.severity != rhs.severity {
                return lhs.severity > rhs.severity
            }
            if lhs.filePath != rhs.filePath {
                return lhs.filePath < rhs.filePath
            }
            if lhs.line != rhs.line {
                return lhs.line < rhs.line
            }
            return lhs.pluginID < rhs.pluginID
        }

        guard deduplicate else { return sorted }

        var seenKeys = Set<String>()
        var unique: [EditorialAuditFinding] = []
        unique.reserveCapacity(sorted.count)
        for item in sorted {
            let dedupKey = "\(item.filePath)|\(item.line)|\(item.severity.rawValue)|\(item.category)|\(item.matchedExcerpt)"
            if seenKeys.insert(dedupKey).inserted {
                unique.append(item)
            }
        }
        return unique
    }
}

// MARK: - Starter Custom Plugin Templates & Archival Audit Report Exporter

/// Curated JavaScript starter templates for authoring custom project- or lab-specific editorial rules in ScholarOS.
public enum EditorialCustomPluginTemplates: Sendable {
    public static let crossReferenceConsistencyTemplate = ScholarPluginManifest(
        id: "custom.crossref-consistency",
        name: "Cross-Reference & Orphan Label Auditor",
        version: "1.0.0",
        summary: "Checks unresolved \\ref/\\eqref/\\cref targets and declared \\label keys that are never referenced in manuscript prose.",
        capabilities: [.readManuscriptAST, .emitEditorialFindings],
        isBuiltIn: false,
        isEnabled: true,
        scriptSource: #"""
        (function () {
          "use strict";
          const xrefs = scholar.getCrossReferences();
          const labels = scholar.getLabels();
          const referencedKeys = {};

          for (let i = 0; i < xrefs.length; i++) {
            const x = xrefs[i];
            referencedKeys[x.targetKey] = true;
            if (!x.isResolved) {
              scholar.emitFinding({
                severity: "SUBMISSION_BLOCKER",
                category: "Unresolved Cross-Reference",
                filePath: x.filePath,
                line: x.line,
                matchedExcerpt: "\\" + x.command + "{" + x.targetKey + "}",
                explanation: "Target label '" + x.targetKey + "' is not declared anywhere in the manuscript workspace."
              });
            }
          }

          for (let j = 0; j < labels.length; j++) {
            const lbl = labels[j];
            if ((lbl.category === "figure" || lbl.category === "table") && !referencedKeys[lbl.key]) {
              scholar.emitFinding({
                severity: "NOTE",
                category: "Unreferenced Float Label",
                filePath: lbl.filePath,
                line: lbl.line,
                matchedExcerpt: "\\label{" + lbl.key + "}",
                explanation: "Float label '" + lbl.key + "' is never referenced in body prose; journals typically require every figure and table to be cited in text."
              });
            }
          }
        })();
        """#
    )

    public static let effectSizeCompletenessTemplate = ScholarPluginManifest(
        id: "custom.effect-size-completeness",
        name: "Effect Size & Confidence Interval Companion Gate",
        version: "1.0.0",
        summary: "Advises pairing null-hypothesis p-values with standardized effect sizes (Cohen's d, Hedges' g, eta^2, OR) or 95% confidence intervals.",
        capabilities: [.readManuscriptAST, .emitEditorialFindings, .suggestProseRewrite],
        isBuiltIn: false,
        isEnabled: false,
        scriptSource: #"""
        (function () {
          "use strict";
          const P_RX = /\bp\s*[=<>]\s*0?\.\d+/i;
          const EFFECT_OR_CI_RX = /\b(Cohen'?s\s+d|Hedges'?\s+g|eta\^2|\\eta\^2|partial\s+eta|95\s*\\?%\s*CI|odds\s+ratio|OR\s*=|d\s*=\s*[+-]?\d+\.\d+)\b/i;

          const files = scholar.listFiles();
          for (let f = 0; f < files.length; f++) {
            const lines = scholar.getAnnotatedLines(files[f]);
            for (let i = 0; i < lines.length; i++) {
              const ln = lines[i];
              if (ln.isComment || ln.inVerbatim) continue;
              if (P_RX.test(ln.commentStripped) && !EFFECT_OR_CI_RX.test(ln.commentStripped)) {
                scholar.emitFinding({
                  severity: "NOTE",
                  category: "Effect Size Reporting",
                  filePath: files[f],
                  line: ln.line,
                  matchedExcerpt: ln.commentStripped.trim(),
                  explanation: "APA 7th JARS recommends accompanying p-values with an effect size estimate (e.g., Cohen's d, eta^2) and 95% CI."
                });
              }
            }
          }
        })();
        """#
    )

    public static var starterTemplates: [ScholarPluginManifest] {
        [crossReferenceConsistencyTemplate, effectSizeCompletenessTemplate]
    }
}

/// Renders `EditorialPluginRunSummary` reports into publication-checklist Markdown or deterministic JSON.
public enum EditorialAuditReportFormatter: Sendable {
    public static func renderMarkdown(
        _ summary: EditorialPluginRunSummary,
        projectTitle: String = "ScholarOS Manuscript"
    ) -> String {
        var lines: [String] = []
        let statusTag = summary.canSubmitCameraReady ? "PASS (Camera-Ready Eligible)" : "HOLD (\(summary.blockerCount) Submission Blocker(s))"
        lines.append("# Editorial & Statistical Rigor Audit — \(projectTitle)")
        lines.append("")
        lines.append("- **Gate Verdict**: \(statusTag)")
        lines.append("- **Submission Blockers**: \(summary.blockerCount)")
        lines.append("- **Rigor Warnings**: \(summary.rigorWarningCount)")
        lines.append("- **Style Suggestions**: \(summary.styleSuggestionCount)")
        lines.append("- **Notes**: \(summary.noteCount)")
        lines.append(String(format: "- **Total Sandbox Runtime**: %.2f ms across %d plugin(s)", summary.totalElapsedMs, summary.executedPluginIDs.count))
        lines.append("")

        if !summary.perPluginTimingsMs.isEmpty {
            lines.append("## Per-Plugin Sandbox Telemetry")
            lines.append("")
            lines.append("| Plugin ID | Execution Time (ms) |")
            lines.append("|---|---:|")
            for id in summary.executedPluginIDs {
                let ms = summary.perPluginTimingsMs[id] ?? 0.0
                lines.append(String(format: "| `%@` | %.2f |", id, ms))
            }
            lines.append("")
        }

        if summary.findings.isEmpty {
            lines.append("_No editorial, rhetorical, statistical, or venue-gate findings detected._")
        } else {
            lines.append("## Detailed Findings (\(summary.findings.count))")
            lines.append("")
            for (idx, f) in summary.findings.enumerated() {
                lines.append("### \(idx + 1). [\(f.severity.rawValue)] \(f.category) — `\(f.filePath):\(f.line)`")
                lines.append("- **Plugin**: \(f.pluginName) (`\(f.pluginID)`)")
                lines.append("- **Excerpt**: `\(f.matchedExcerpt)`")
                lines.append("- **Explanation**: \(f.explanation)")
                if let rewrite = f.suggestedRewrite {
                    lines.append("- **Suggested Scholarly Rewrite**: `\(rewrite)`")
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }
}
