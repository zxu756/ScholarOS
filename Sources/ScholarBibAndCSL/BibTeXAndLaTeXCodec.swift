import Foundation
import ScholarModels

// MARK: - BibTeX Diagnostics, AST Document & Serializer Configuration

public struct BibTeXParseDiagnostic: Sendable, Codable, Hashable, Equatable {
    public enum Severity: String, Sendable, Codable, Hashable {
        case info
        case warning
    }

    public let line: Int
    public let column: Int
    public let severity: Severity
    public let citeKey: String?
    public let message: String

    public init(
        line: Int,
        column: Int,
        severity: Severity,
        citeKey: String? = nil,
        message: String
    ) {
        self.line = line
        self.column = column
        self.severity = severity
        self.citeKey = citeKey
        self.message = message
    }
}

public struct BibTeXDocument: Sendable, Codable, Hashable {
    public var preambles: [String]
    public var macros: [String: String]
    public var comments: [String]
    public var entries: [BibliographyEntry]
    public var unmappedFieldsByCiteKey: [String: [String: String]]
    public var diagnostics: [BibTeXParseDiagnostic]

    public init(
        preambles: [String] = [],
        macros: [String: String] = [:],
        comments: [String] = [],
        entries: [BibliographyEntry] = [],
        unmappedFieldsByCiteKey: [String: [String: String]] = [:],
        diagnostics: [BibTeXParseDiagnostic] = []
    ) {
        self.preambles = preambles
        self.macros = macros
        self.comments = comments
        self.entries = entries
        self.unmappedFieldsByCiteKey = unmappedFieldsByCiteKey
        self.diagnostics = diagnostics
    }
}

public struct BibTeXSerializerOptions: Sendable, Codable, Hashable {
    public var sortEntriesByCiteKey: Bool
    public var alignEqualsColumn: Int
    public var protectAcronymsInTitle: Bool
    public var escapeUnicodeToLaTeX: Bool
    public var includeFirewallMetadataFields: Bool
    public var includeCitationGraphFields: Bool
    public var useBibLaTeXPreprintOnlineType: Bool

    public init(
        sortEntriesByCiteKey: Bool = false,
        alignEqualsColumn: Int = 18,
        protectAcronymsInTitle: Bool = true,
        escapeUnicodeToLaTeX: Bool = false,
        includeFirewallMetadataFields: Bool = true,
        includeCitationGraphFields: Bool = true,
        useBibLaTeXPreprintOnlineType: Bool = false
    ) {
        self.sortEntriesByCiteKey = sortEntriesByCiteKey
        self.alignEqualsColumn = max(4, alignEqualsColumn)
        self.protectAcronymsInTitle = protectAcronymsInTitle
        self.escapeUnicodeToLaTeX = escapeUnicodeToLaTeX
        self.includeFirewallMetadataFields = includeFirewallMetadataFields
        self.includeCitationGraphFields = includeCitationGraphFields
        self.useBibLaTeXPreprintOnlineType = useBibLaTeXPreprintOnlineType
    }

    public static let canonical = BibTeXSerializerOptions()
}

// MARK: - Bidirectional LaTeX Diacritic, Ligature & Math-Text Codec

public struct LaTeXTextCodec: Sendable {

    private static let combiningScalarByCommand: [Character: UnicodeScalar] = [
        "\"": "\u{0308}", // diaeresis / umlaut
        "'":  "\u{0301}", // acute
        "`":  "\u{0300}", // grave
        "^":  "\u{0302}", // circumflex
        "~":  "\u{0303}", // tilde
        "=":  "\u{0304}", // macron
        ".":  "\u{0307}", // dot above
        "u":  "\u{0306}", // breve
        "v":  "\u{030C}", // caron / hacek
        "H":  "\u{030B}", // double acute
        "c":  "\u{0327}", // cedilla
        "k":  "\u{0328}", // ogonek
        "d":  "\u{0323}", // dot below
        "b":  "\u{0331}", // macron below
        "r":  "\u{030A}"  // ring above
    ]

    private static let namedCommandMap: [String: String] = [
        "aa": "å",
        "AA": "Å",
        "ae": "æ",
        "AE": "Æ",
        "oe": "œ",
        "OE": "Œ",
        "o": "ø",
        "O": "Ø",
        "l": "ł",
        "L": "Ł",
        "ss": "ß",
        "SS": "ẞ",
        "dh": "ð",
        "DH": "Ð",
        "th": "þ",
        "TH": "Þ",
        "dj": "đ",
        "DJ": "Đ",
        "ng": "ŋ",
        "NG": "Ŋ",
        "i": "ı",
        "j": "ȷ",
        "dag": "†",
        "ddag": "‡",
        "S": "§",
        "P": "¶",
        "copyright": "©",
        "textregistered": "®",
        "texttrademark": "™",
        "pounds": "£",
        "euro": "€",
        "texteuro": "€",
        "dots": "…",
        "ldots": "…",
        "cdots": "⋯",
        "textendash": "–",
        "textemdash": "—",
        "textquoteleft": "‘",
        "textquoteright": "’",
        "textquotedblleft": "“",
        "textquotedblright": "”",
        "textbackslash": "\\",
        "textasciitilde": "~",
        "textasciicircum": "^",
        "textbar": "|",
        "textless": "<",
        "textgreater": ">",
        "textdegree": "°",
        "LaTeX": "LaTeX",
        "TeX": "TeX",
        "BibTeX": "BibTeX"
    ]

    private static let mathCommandMap: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "pm": "±", "mp": "∓",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼",
        "equiv": "≡", "propto": "∝", "infty": "∞", "partial": "∂",
        "nabla": "∇", "forall": "∀", "exists": "∃", "in": "∈",
        "notin": "∉", "subset": "⊂", "subseteq": "⊆", "cup": "∪",
        "cap": "∩", "emptyset": "∅", "rightarrow": "→", "to": "→",
        "leftarrow": "←", "leftrightarrow": "↔", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "ell": "ℓ",
        "dagger": "†", "ddagger": "‡", "star": "⋆", "circ": "∘"
    ]

    private static let wrapperFormattingCommands: Set<String> = [
        "emph", "textit", "textbf", "textrm", "texttt", "textsc", "textsf",
        "textnormal", "textup", "mathrm", "mathbf", "mathsf", "mathtt",
        "mathcal", "mathbb", "mathfrak", "mbox", "hbox", "url", "href",
        "mkbibquote", "enquote"
    ]

    private static let superscriptMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ"
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "i": "ᵢ",
        "j": "ⱼ", "k": "ₖ", "n": "ₙ", "m": "ₘ", "p": "ₚ",
        "s": "ₛ", "t": "ₜ"
    ]

    private static let unicodeToLaTeXMap: [Character: String] = [
        "ä": "{\\\"a}", "ö": "{\\\"o}", "ü": "{\\\"u}", "ë": "{\\\"e}", "ï": "{\\\"\\i}", "ÿ": "{\\\"y}",
        "Ä": "{\\\"A}", "Ö": "{\\\"O}", "Ü": "{\\\"U}", "Ë": "{\\\"E}", "Ï": "{\\\"I}",
        "á": "{\\'a}", "é": "{\\'e}", "í": "{\\'\\i}", "ó": "{\\'o}", "ú": "{\\'u}", "ý": "{\\'y}",
        "Á": "{\\'A}", "É": "{\\'E}", "Í": "{\\'I}", "Ó": "{\\'O}", "Ú": "{\\'U}", "Ý": "{\\'Y}",
        "à": "{\\`a}", "è": "{\\`e}", "ì": "{\\`\\i}", "ò": "{\\`o}", "ù": "{\\`u}",
        "À": "{\\`A}", "È": "{\\`E}", "Ì": "{\\`I}", "Ò": "{\\`O}", "Ù": "{\\`U}",
        "â": "{\\^a}", "ê": "{\\^e}", "î": "{\\^\\i}", "ô": "{\\^o}", "û": "{\\^u}",
        "Â": "{\\^A}", "Ê": "{\\^E}", "Î": "{\\^I}", "Ô": "{\\^O}", "Û": "{\\^U}",
        "ã": "{\\~a}", "ñ": "{\\~n}", "õ": "{\\~o}",
        "Ã": "{\\~A}", "Ñ": "{\\~N}", "Õ": "{\\~O}",
        "ç": "{\\c{c}}", "Ç": "{\\c{C}}",
        "ş": "{\\c{s}}", "Ş": "{\\c{S}}",
        "ğ": "{\\u{g}}", "Ğ": "{\\u{G}}",
        "č": "{\\v{c}}", "Č": "{\\v{C}}",
        "š": "{\\v{s}}", "Š": "{\\v{S}}",
        "ž": "{\\v{z}}", "Ž": "{\\v{Z}}",
        "ř": "{\\v{r}}", "Ř": "{\\v{R}}",
        "ő": "{\\H{o}}", "Ő": "{\\H{O}}",
        "ű": "{\\H{u}}", "Ű": "{\\H{U}}",
        "å": "{\\aa}", "Å": "{\\AA}",
        "æ": "{\\ae}", "Æ": "{\\AE}",
        "œ": "{\\oe}", "Œ": "{\\OE}",
        "ø": "{\\o}", "Ø": "{\\O}",
        "ł": "{\\l}", "Ł": "{\\L}",
        "ß": "{\\ss}", "ẞ": "{\\SS}",
        "đ": "{\\dj}", "Đ": "{\\DJ}",
        "ı": "{\\i}"
    ]

    public init() {}

    /// Decodes BibTeX/LaTeX diacritics, character commands, ligatures, protective braces, and inline math into clean UTF-8 NFC text.
    public func decode(_ input: String) -> String {
        if input.isEmpty { return "" }
        let chars = Array(input)
        var out = String()
        out.reserveCapacity(chars.count)

        var idx = 0
        var inMathMode = false

        while idx < chars.count {
            let ch = chars[idx]

            // Inline math toggle `$`
            if ch == "$" {
                if idx + 1 < chars.count && chars[idx + 1] == "$" {
                    inMathMode.toggle()
                    idx += 2
                } else {
                    inMathMode.toggle()
                    idx += 1
                }
                continue
            }

            // Math superscript / subscript
            if inMathMode && (ch == "^" || ch == "_") {
                let isSuper = (ch == "^")
                idx += 1
                let group = consumeSingleTokenOrBraceGroup(chars, index: &idx)
                let decodedGroup = decode(group)
                let table = isSuper ? Self.superscriptMap : Self.subscriptMap
                var mappedAll = true
                var mapped = ""
                for gc in decodedGroup {
                    if let sup = table[gc] {
                        mapped.append(sup)
                    } else {
                        mappedAll = false
                        break
                    }
                }
                if mappedAll && !mapped.isEmpty {
                    out.append(mapped)
                } else {
                    out.append(isSuper ? "^" : "_")
                    if decodedGroup.count > 1 {
                        out.append("(")
                        out.append(decodedGroup)
                        out.append(")")
                    } else {
                        out.append(decodedGroup)
                    }
                }
                continue
            }

            // Unescaped protective braces `{...}`
            if ch == "{" {
                if let (inner, nextIndex) = extractBalancedBraces(chars, from: idx) {
                    out.append(decode(inner))
                    idx = nextIndex
                    continue
                } else {
                    idx += 1
                    continue
                }
            }
            if ch == "}" {
                idx += 1
                continue
            }

            // Non-breaking space `~`
            if ch == "~" {
                out.append(" ")
                idx += 1
                continue
            }

            // TeX ligatures (`---`, `--`, ``, '') when not inside URLs/DOIs
            if ch == "-" && !inMathMode {
                if idx + 2 < chars.count && chars[idx + 1] == "-" && chars[idx + 2] == "-" {
                    out.append("—")
                    idx += 3
                    continue
                }
                if idx + 1 < chars.count && chars[idx + 1] == "-" {
                    out.append("–")
                    idx += 2
                    continue
                }
            }
            if ch == "`" && idx + 1 < chars.count && chars[idx + 1] == "`" {
                out.append("“")
                idx += 2
                continue
            }
            if ch == "'" && idx + 1 < chars.count && chars[idx + 1] == "'" {
                out.append("”")
                idx += 2
                continue
            }

            // Backslash LaTeX command
            if ch == "\\" {
                idx += 1
                if idx >= chars.count {
                    break
                }
                let cmdChar = chars[idx]

                // 1) Escaped single punctuation symbols: \& \% \$ \# \_ \{ \} \  \, \; \!
                switch cmdChar {
                case "&", "%", "$", "#", "_", "{", "}":
                    out.append(cmdChar)
                    idx += 1
                    continue
                case " ", "\t", "\n":
                    out.append(" ")
                    idx += 1
                    continue
                case ",", ";":
                    out.append("\u{2009}")
                    idx += 1
                    continue
                case "!":
                    idx += 1
                    continue
                case "\\":
                    out.append("\n")
                    idx += 1
                    continue
                default:
                    break
                }

                // 2) Non-letter single-char combining accents: \" \' \` \^ \~ \= \.
                if !cmdChar.isLetter, let combining = Self.combiningScalarByCommand[cmdChar] {
                    idx += 1
                    skipInlineSpaces(chars, index: &idx)
                    let baseRaw = consumeSingleTokenOrBraceGroup(chars, index: &idx)
                    let baseDecoded = decodeBaseForAccent(baseRaw)
                    out.append(applyCombiningAccent(combining, to: baseDecoded))
                    continue
                }

                // 3) Alphabetic control word: \aa, \ss, \c{c}, \v{s}, \emph{...}, \alpha, etc.
                if cmdChar.isLetter {
                    let wordStart = idx
                    while idx < chars.count && chars[idx].isLetter {
                        idx += 1
                    }
                    let word = String(chars[wordStart..<idx])

                    // Tie accent \t{oo}
                    if word == "t" {
                        let saved = idx
                        skipInlineSpaces(chars, index: &idx)
                        if idx < chars.count && chars[idx] == "{" {
                            let arg = consumeSingleTokenOrBraceGroup(chars, index: &idx)
                            let decodedArg = decode(arg)
                            if decodedArg.count >= 2 {
                                var scalars = Array(decodedArg.unicodeScalars)
                                scalars.insert("\u{0361}", at: 1)
                                out.append(String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping)
                                continue
                            } else {
                                out.append(decodedArg)
                                continue
                            }
                        } else {
                            idx = saved
                        }
                    }

                    // Letter-named combining accents (\c, \v, \u, \H, \k, \d, \b, \r)
                    // Require either `{...}` or whitespace before argument so `\copyright` is not misread as `\c`!
                    if word.count == 1,
                       let singleLetter = word.first,
                       let combining = Self.combiningScalarByCommand[singleLetter] {
                        if idx < chars.count && (chars[idx] == "{" || chars[idx] == " " || chars[idx] == "\t" || chars[idx] == "\\") {
                            skipInlineSpaces(chars, index: &idx)
                            let baseRaw = consumeSingleTokenOrBraceGroup(chars, index: &idx)
                            let baseDecoded = decodeBaseForAccent(baseRaw)
                            out.append(applyCombiningAccent(combining, to: baseDecoded))
                            continue
                        }
                    }

                    // Formatting wrappers: \emph{...}, \textbf{...}, \href{url}{label}
                    if Self.wrapperFormattingCommands.contains(word) {
                        skipInlineSpaces(chars, index: &idx)
                        if word == "href" {
                            if idx < chars.count && chars[idx] == "{" {
                                _ = consumeSingleTokenOrBraceGroup(chars, index: &idx)
                                skipInlineSpaces(chars, index: &idx)
                            }
                        }
                        if idx < chars.count && chars[idx] == "{" {
                            let inner = consumeSingleTokenOrBraceGroup(chars, index: &idx)
                            out.append(decode(inner))
                            continue
                        }
                    }

                    // Named character commands (\aa, \ss, \o, \l, \ae, \oe, ...)
                    if let replacement = Self.namedCommandMap[word] {
                        out.append(replacement)
                        // Consume empty `{}` or trailing space after control word in LaTeX (`\ss{}`, `\aa `)
                        if idx + 1 < chars.count && chars[idx] == "{" && chars[idx + 1] == "}" {
                            idx += 2
                        } else if idx < chars.count && chars[idx] == " " {
                            idx += 1
                        }
                        continue
                    }

                    // Math/symbol commands (\alpha, \times, \leq, ...)
                    if let mathSym = Self.mathCommandMap[word] {
                        out.append(mathSym)
                        if idx + 1 < chars.count && chars[idx] == "{" && chars[idx + 1] == "}" {
                            idx += 2
                        } else if idx < chars.count && chars[idx] == " " && inMathMode {
                            idx += 1
                        }
                        continue
                    }

                    // Unknown control word: if followed by `{...}`, decode inner group; else drop command slash
                    if idx < chars.count && chars[idx] == "{" {
                        let inner = consumeSingleTokenOrBraceGroup(chars, index: &idx)
                        out.append(decode(inner))
                    } else {
                        if idx < chars.count && chars[idx] == " " {
                            idx += 1
                        }
                    }
                    continue
                }

                // Fallback for unrecognized escaped symbol
                out.append(cmdChar)
                idx += 1
                continue
            }

            out.append(ch)
            idx += 1
        }

        return normalizeCollapsedWhitespace(out.precomposedStringWithCanonicalMapping)
    }

    /// Encodes plain UTF-8 text into BibTeX-safe text, optionally converting non-ASCII diacritics to LaTeX macros and protecting mixed-case acronyms.
    public func encode(
        _ input: String,
        escapeUnicodeToLaTeX: Bool = false,
        protectAcronymsInTitle: Bool = false,
        preserveRawURLCharacters: Bool = false
    ) -> String {
        if input.isEmpty { return "" }
        if preserveRawURLCharacters {
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let base: String
        if protectAcronymsInTitle {
            base = protectMixedCaseWords(in: input, escapeUnicodeToLaTeX: escapeUnicodeToLaTeX)
        } else {
            base = encodeCharacters(in: input, escapeUnicodeToLaTeX: escapeUnicodeToLaTeX)
        }
        return base
    }

    public func stripProtectiveBraces(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count && (chars[i + 1] == "{" || chars[i + 1] == "}") {
                result.append(chars[i + 1])
                i += 2
                continue
            }
            if chars[i] != "{" && chars[i] != "}" {
                result.append(chars[i])
            }
            i += 1
        }
        return result
    }

    // MARK: - Private LaTeX Decoding & Encoding Helpers

    private func extractBalancedBraces(_ chars: [Character], from start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == "{" else { return nil }
        var depth = 0
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let inner = String(chars[(start + 1)..<i])
                    return (inner, i + 1)
                }
            }
            i += 1
        }
        return nil
    }

    private func skipInlineSpaces(_ chars: [Character], index: inout Int) {
        while index < chars.count && (chars[index] == " " || chars[index] == "\t") {
            index += 1
        }
    }

    private func consumeSingleTokenOrBraceGroup(_ chars: [Character], index: inout Int) -> String {
        guard index < chars.count else { return "" }
        if chars[index] == "{" {
            if let (inner, next) = extractBalancedBraces(chars, from: index) {
                index = next
                return inner
            }
            index += 1
            return ""
        }
        if chars[index] == "\\" {
            let start = index
            index += 1
            if index < chars.count && chars[index].isLetter {
                while index < chars.count && chars[index].isLetter {
                    index += 1
                }
                if index + 1 < chars.count && chars[index] == "{" && chars[index + 1] == "}" {
                    index += 2
                }
            } else if index < chars.count {
                index += 1
            }
            return String(chars[start..<index])
        }
        let ch = chars[index]
        index += 1
        return String(ch)
    }

    private func decodeBaseForAccent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "\\i" || trimmed == "{\\i}" {
            return "i"
        }
        if trimmed == "\\j" || trimmed == "{\\j}" {
            return "j"
        }
        let decoded = decode(trimmed)
        if decoded == "ı" { return "i" }
        if decoded == "ȷ" { return "j" }
        return decoded
    }

    private func applyCombiningAccent(_ combining: UnicodeScalar, to base: String) -> String {
        guard !base.isEmpty else {
            return String(combining)
        }
        var result = ""
        var applied = false
        for ch in base {
            if !applied {
                var scalars = Array(String(ch).unicodeScalars)
                scalars.append(combining)
                let composed = String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
                result.append(composed)
                applied = true
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private func normalizeCollapsedWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var previousWasSpace = false
        for ch in text {
            if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
                if !previousWasSpace {
                    result.append(" ")
                    previousWasSpace = true
                }
            } else {
                result.append(ch)
                previousWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func encodeCharacters(in text: String, escapeUnicodeToLaTeX: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        for ch in text {
            switch ch {
            case "&":
                out.append("{\\&}")
            case "%":
                out.append("\\%")
            case "#":
                out.append("\\#")
            case "_":
                out.append("\\_")
            default:
                if escapeUnicodeToLaTeX, let macro = Self.unicodeToLaTeXMap[ch] {
                    out.append(macro)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    private func protectMixedCaseWords(in title: String, escapeUnicodeToLaTeX: Bool) -> String {
        let tokens = title.split(separator: " ", omittingEmptySubsequences: false)
        var encodedTokens: [String] = []
        encodedTokens.reserveCapacity(tokens.count)

        for (tokenIndex, rawToken) in tokens.enumerated() {
            let token = String(rawToken)
            if token.isEmpty {
                encodedTokens.append("")
                continue
            }
            let letters = token.filter(\.isLetter)
            let uppercaseCount = letters.filter(\.isUppercase).count
            let hasInternalUppercase = token.dropFirst().contains(where: \.isUppercase)
            let shouldProtect = (uppercaseCount >= 2) || (tokenIndex > 0 && hasInternalUppercase)

            let encoded = encodeCharacters(in: token, escapeUnicodeToLaTeX: escapeUnicodeToLaTeX)
            if shouldProtect && !token.hasPrefix("{") {
                encodedTokens.append("{\(encoded)}")
            } else {
                encodedTokens.append(encoded)
            }
        }
        return encodedTokens.joined(separator: " ")
    }
}

// MARK: - BibTeX Name Decomposition & Serialization ("Last, First", "First von Last", "{Corporate}")

public struct BibTeXAuthorParser: Sendable {

    public static func parseAuthors(
        _ rawAuthorField: String,
        orcidField: String? = nil,
        codec: LaTeXTextCodec = LaTeXTextCodec()
    ) -> [BibAuthor] {
        let segments = splitTopLevelAnd(rawAuthorField)
        if segments.isEmpty { return [] }

        let orcids: [String?] = parseORCIDList(orcidField)
        var parsedAuthors: [BibAuthor] = []
        parsedAuthors.reserveCapacity(segments.count)

        for (index, rawSegment) in segments.enumerated() {
            let trimmed = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.lowercased() == "others" {
                parsedAuthors.append(BibAuthor(givenName: "", familyName: "et al."))
                continue
            }

            let (cleanedSegment, inlineORCID) = extractInlineORCID(from: trimmed)
            let resolvedORCID = inlineORCID ?? (index < orcids.count ? orcids[index] : nil)

            // Corporate / institutional author enclosed entirely in single outer braces `{OpenAI}` or `{World Health Organization}`
            if isSingleOuterBracedGroup(cleanedSegment) {
                let inner = String(cleanedSegment.dropFirst().dropLast())
                let corporateName = codec.decode(inner)
                if !corporateName.isEmpty {
                    parsedAuthors.append(
                        BibAuthor(givenName: "", familyName: corporateName, orcid: resolvedORCID)
                    )
                }
                continue
            }

            let commaParts = splitAtBraceDepthZero(cleanedSegment, delimiter: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            if commaParts.count >= 3 {
                // `von Last, Jr, First`
                let family = codec.decode("\(commaParts[0]), \(commaParts[1])")
                let given = codec.decode(commaParts[2...].joined(separator: " "))
                parsedAuthors.append(BibAuthor(givenName: given, familyName: family, orcid: resolvedORCID))
            } else if commaParts.count == 2 {
                // `von Last, First`
                let family = codec.decode(commaParts[0])
                let given = codec.decode(commaParts[1])
                parsedAuthors.append(BibAuthor(givenName: given, familyName: family, orcid: resolvedORCID))
            } else {
                // `First Middle von Last`
                let words = splitWhitespaceAtBraceDepthZero(cleanedSegment)
                if words.isEmpty { continue }
                if words.count == 1 {
                    let single = codec.decode(words[0])
                    parsedAuthors.append(BibAuthor(givenName: "", familyName: single, orcid: resolvedORCID))
                } else {
                    // Detect lowercase `von` particle sequence preceding final surname word(s)
                    var vonStartIndex: Int?
                    for wi in 1..<(words.count - 1) {
                        let w = words[wi]
                        if !w.hasPrefix("{"), let firstLetter = codec.decode(w).first(where: \.isLetter), firstLetter.isLowercase {
                            vonStartIndex = wi
                            break
                        }
                    }
                    let splitPoint = vonStartIndex ?? (words.count - 1)
                    let givenRaw = words[0..<splitPoint].joined(separator: " ")
                    let familyRaw = words[splitPoint..<words.count].joined(separator: " ")
                    parsedAuthors.append(
                        BibAuthor(
                            givenName: codec.decode(givenRaw),
                            familyName: codec.decode(familyRaw),
                            orcid: resolvedORCID
                        )
                    )
                }
            }
        }

        return parsedAuthors
    }

    public static func serializeAuthors(
        _ authors: [BibAuthor],
        codec: LaTeXTextCodec = LaTeXTextCodec(),
        escapeUnicodeToLaTeX: Bool = false
    ) -> String {
        authors.map { author in
            let fam = codec.encode(author.familyName, escapeUnicodeToLaTeX: escapeUnicodeToLaTeX)
            let giv = codec.encode(author.givenName, escapeUnicodeToLaTeX: escapeUnicodeToLaTeX)
            if giv.isEmpty {
                if fam.lowercased() == "et al." {
                    return "others"
                }
                return "{\(fam)}"
            }
            return "\(fam), \(giv)"
        }.joined(separator: " and ")
    }

    // MARK: - Top-Level Splitting Helpers

    private static func splitTopLevelAnd(_ raw: String) -> [String] {
        let chars = Array(raw)
        var parts: [String] = []
        var depth = 0
        var segmentStart = 0
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if c == "{" {
                depth += 1
                i += 1
                continue
            }
            if c == "}" {
                depth = max(0, depth - 1)
                i += 1
                continue
            }

            if depth == 0 && (c == " " || c == "\t" || c == "\n" || c == "\r") {
                var wsEnd = i
                while wsEnd < chars.count && (chars[wsEnd] == " " || chars[wsEnd] == "\t" || chars[wsEnd] == "\n" || chars[wsEnd] == "\r") {
                    wsEnd += 1
                }
                if wsEnd + 3 < chars.count {
                    let c0 = chars[wsEnd]
                    let c1 = chars[wsEnd + 1]
                    let c2 = chars[wsEnd + 2]
                    let c3 = chars[wsEnd + 3]
                    let isAnd = (c0 == "a" || c0 == "A") && (c1 == "n" || c1 == "N") && (c2 == "d" || c2 == "D")
                    let isTrailingSpace = (c3 == " " || c3 == "\t" || c3 == "\n" || c3 == "\r")
                    if isAnd && isTrailingSpace {
                        parts.append(String(chars[segmentStart..<i]))
                        var afterAnd = wsEnd + 3
                        while afterAnd < chars.count && (chars[afterAnd] == " " || chars[afterAnd] == "\t" || chars[afterAnd] == "\n" || chars[afterAnd] == "\r") {
                            afterAnd += 1
                        }
                        segmentStart = afterAnd
                        i = afterAnd
                        continue
                    }
                }
                i = wsEnd
                continue
            }
            i += 1
        }

        if segmentStart <= chars.count {
            let tail = String(chars[segmentStart..<chars.count])
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(tail)
            }
        }
        return parts
    }

    private static func splitAtBraceDepthZero(_ text: String, delimiter: Character) -> [String] {
        let chars = Array(text)
        var parts: [String] = []
        var depth = 0
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if c == "{" { depth += 1 }
            else if c == "}" { depth = max(0, depth - 1) }
            else if c == delimiter && depth == 0 {
                parts.append(String(chars[start..<i]))
                start = i + 1
            }
            i += 1
        }
        parts.append(String(chars[start..<chars.count]))
        return parts
    }

    private static func splitWhitespaceAtBraceDepthZero(_ text: String) -> [String] {
        let chars = Array(text)
        var words: [String] = []
        var depth = 0
        var tokenStart: Int?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                if tokenStart == nil { tokenStart = i }
                i += 2
                continue
            }
            if c == "{" {
                if tokenStart == nil { tokenStart = i }
                depth += 1
            } else if c == "}" {
                depth = max(0, depth - 1)
            } else if depth == 0 && (c == " " || c == "\t" || c == "\n" || c == "\r" || c == "~") {
                if let ts = tokenStart {
                    words.append(String(chars[ts..<i]))
                    tokenStart = nil
                }
            } else {
                if tokenStart == nil { tokenStart = i }
            }
            i += 1
        }
        if let ts = tokenStart {
            words.append(String(chars[ts..<chars.count]))
        }
        return words
    }

    private static func isSingleOuterBracedGroup(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 2, chars.first == "{", chars.last == "}" else { return false }
        var depth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                i += 2
                continue
            }
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 && i < chars.count - 1 {
                    return false
                }
            }
            i += 1
        }
        return depth == 0
    }

    private static func parseORCIDList(_ orcidField: String?) -> [String?] {
        guard let orcidField, !orcidField.isEmpty else { return [] }
        return orcidField
            .split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { raw in
                let cleaned = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "https://orcid.org/", with: "")
                    .replacingOccurrences(of: "http://orcid.org/", with: "")
                return cleaned.isEmpty ? nil : cleaned
            }
    }

    private static func extractInlineORCID(from text: String) -> (String, String?) {
        guard let openIdx = text.lastIndex(of: "["),
              let closeIdx = text.lastIndex(of: "]"),
              openIdx < closeIdx else {
            return (text, nil)
        }
        let candidate = String(text[text.index(after: openIdx)..<closeIdx])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://orcid.org/", with: "")
            .replacingOccurrences(of: "ORCID:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let compact = candidate.filter { $0 != "-" }
        let looksLikeORCID = compact.count == 16 && compact.dropLast().allSatisfy(\.isNumber)
            && (compact.last?.isNumber == true || compact.last == "X" || compact.last == "x")
        guard looksLikeORCID else {
            return (text, nil)
        }
        let stripped = String(text[..<openIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, candidate.uppercased())
    }
}

// MARK: - Handwritten Recursive-Descent BibTeX / BibLaTeX Parser & Canonical Serializer

public struct BibTeXCodec: Sendable {

    public static let defaultMacros: [String: String] = [
        // Standard BibTeX months
        "jan": "January", "feb": "February", "mar": "March", "apr": "April",
        "may": "May", "jun": "June", "jul": "July", "aug": "August",
        "sep": "September", "oct": "October", "nov": "November", "dec": "December",
        // Major CS / AI / ML / Systems / Science venues
        "cvpr": "IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)",
        "iccv": "IEEE/CVF International Conference on Computer Vision (ICCV)",
        "eccv": "European Conference on Computer Vision (ECCV)",
        "neurips": "Advances in Neural Information Processing Systems (NeurIPS)",
        "nips": "Advances in Neural Information Processing Systems (NeurIPS)",
        "icml": "International Conference on Machine Learning (ICML)",
        "iclr": "International Conference on Learning Representations (ICLR)",
        "acl": "Annual Meeting of the Association for Computational Linguistics (ACL)",
        "emnlp": "Conference on Empirical Methods in Natural Language Processing (EMNLP)",
        "naacl": "Conference of the North American Chapter of the Association for Computational Linguistics (NAACL)",
        "aaai": "AAAI Conference on Artificial Intelligence",
        "ijcai": "International Joint Conference on Artificial Intelligence (IJCAI)",
        "chi": "ACM CHI Conference on Human Factors in Computing Systems",
        "sigmod": "ACM SIGMOD International Conference on Management of Data",
        "vldb": "Proceedings of the VLDB Endowment",
        "kdd": "ACM SIGKDD Conference on Knowledge Discovery and Data Mining",
        "osdi": "USENIX Symposium on Operating Systems Design and Implementation (OSDI)",
        "sosp": "ACM Symposium on Operating Systems Principles (SOSP)",
        "pldi": "ACM SIGPLAN Conference on Programming Language Design and Implementation (PLDI)",
        "popl": "ACM SIGPLAN Symposium on Principles of Programming Languages (POPL)",
        "icse": "IEEE/ACM International Conference on Software Engineering (ICSE)",
        "cacm": "Communications of the ACM",
        "jacm": "Journal of the ACM",
        "tpami": "IEEE Transactions on Pattern Analysis and Machine Intelligence",
        "pami": "IEEE Transactions on Pattern Analysis and Machine Intelligence",
        "ijcv": "International Journal of Computer Vision",
        "jmlr": "Journal of Machine Learning Research",
        "tacl": "Transactions of the Association for Computational Linguistics",
        "pnas": "Proceedings of the National Academy of Sciences"
    ]

    public let options: BibTeXSerializerOptions
    public let customMacros: [String: String]
    public let latexCodec: LaTeXTextCodec

    public init(
        options: BibTeXSerializerOptions = .canonical,
        customMacros: [String: String] = [:],
        latexCodec: LaTeXTextCodec = LaTeXTextCodec()
    ) {
        self.options = options
        var normalizedMacros: [String: String] = [:]
        for (k, v) in customMacros {
            normalizedMacros[k.lowercased()] = v
        }
        self.customMacros = normalizedMacros
        self.latexCodec = latexCodec
    }

    // MARK: - Public Parse & Serialize Entrypoints

    public func parse(_ source: String) throws -> [BibliographyEntry] {
        try parseDocument(source).entries
    }

    public func parseDocument(_ source: String) throws -> BibTeXDocument {
        var scanner = BibTeXScanner(source: source)
        var macros = Self.defaultMacros
        for (k, v) in customMacros {
            macros[k] = v
        }
        var userMacros: [String: String] = [:]
        var preambles: [String] = []
        var comments: [String] = []
        var entries: [BibliographyEntry] = []
        var unmappedByKey: [String: [String: String]] = [:]
        var diagnostics: [BibTeXParseDiagnostic] = []

        while !scanner.isAtEnd {
            scanner.skipInterEntryTrivia(commentsSink: &comments)
            if scanner.isAtEnd { break }

            let entryLine = scanner.line
            guard scanner.consumeIf("@") else {
                scanner.advance()
                continue
            }

            scanner.skipWhitespaceAndLineComments()
            let rawTypeName = scanner.readIdentifier()
            guard !rawTypeName.isEmpty else {
                throw ScholarOSError.bibliographyParseFailure(
                    format: "BibTeX",
                    line: entryLine,
                    detail: "Expected entry type identifier after '@'."
                )
            }

            let lowerType = rawTypeName.lowercased()
            scanner.skipWhitespaceAndLineComments()

            // `@comment` without braces (line comment form) or with `{...}` / `(...)`
            if lowerType == "comment" {
                if scanner.peek() == "{" || scanner.peek() == "(" {
                    let closeChar: Character = (scanner.peek() == "{") ? "}" : ")"
                    scanner.advance()
                    let commentBody = try scanner.readBalancedRawBody(closingDelimiter: closeChar, startLine: entryLine)
                    comments.append(commentBody.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    comments.append(scanner.readRestOfLine().trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continue
            }

            guard let openDelim = scanner.peek(), (openDelim == "{" || openDelim == "(") else {
                throw ScholarOSError.bibliographyParseFailure(
                    format: "BibTeX",
                    line: scanner.line,
                    detail: "Expected '{' or '(' to open @\(rawTypeName) entry."
                )
            }
            let closeDelim: Character = (openDelim == "{") ? "}" : ")"
            scanner.advance()
            scanner.skipWhitespaceAndLineComments()

            // `@preamble{ ... }`
            if lowerType == "preamble" {
                let value = try parseValueExpression(
                    scanner: &scanner,
                    macros: macros,
                    closingEntryDelimiter: closeDelim,
                    diagnostics: &diagnostics,
                    citeKeyContext: nil
                )
                scanner.skipWhitespaceAndLineComments()
                _ = scanner.consumeIf(",")
                scanner.skipWhitespaceAndLineComments()
                guard scanner.consumeIf(closeDelim) else {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: scanner.line,
                        detail: "Unclosed @preamble block starting at line \(entryLine)."
                    )
                }
                preambles.append(value)
                continue
            }

            // `@string{ key = value }`
            if lowerType == "string" {
                let macroName = scanner.readFieldOrMacroName()
                guard !macroName.isEmpty else {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: scanner.line,
                        detail: "Expected macro identifier inside @string definition."
                    )
                }
                scanner.skipWhitespaceAndLineComments()
                guard scanner.consumeIf("=") else {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: scanner.line,
                        detail: "Expected '=' in @string{\(macroName) = ...}."
                    )
                }
                scanner.skipWhitespaceAndLineComments()
                let macroValue = try parseValueExpression(
                    scanner: &scanner,
                    macros: macros,
                    closingEntryDelimiter: closeDelim,
                    diagnostics: &diagnostics,
                    citeKeyContext: nil
                )
                scanner.skipWhitespaceAndLineComments()
                _ = scanner.consumeIf(",")
                scanner.skipWhitespaceAndLineComments()
                guard scanner.consumeIf(closeDelim) else {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: scanner.line,
                        detail: "Unclosed @string{\(macroName)} starting at line \(entryLine)."
                    )
                }
                let lowerKey = macroName.lowercased()
                macros[lowerKey] = macroValue
                userMacros[lowerKey] = macroValue
                continue
            }

            // Standard bibliographic entry `@article{citeKey, field = val, ...}`
            let keyLine = scanner.line
            let citeKey = scanner.readCitationKey(closingDelimiter: closeDelim)
            guard !citeKey.isEmpty else {
                throw ScholarOSError.bibliographyParseFailure(
                    format: "BibTeX",
                    line: keyLine,
                    detail: "Missing citation key in @\(rawTypeName) entry."
                )
            }

            scanner.skipWhitespaceAndLineComments()
            var rawFields: [String: String] = [:]
            var fieldOrder: [String] = []

            if scanner.consumeIf(closeDelim) {
                // Empty entry body `@misc{key}`
            } else {
                guard scanner.consumeIf(",") else {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: scanner.line,
                        detail: "Expected ',' after citation key '\(citeKey)' in @\(rawTypeName)."
                    )
                }

                while true {
                    scanner.skipWhitespaceAndLineComments()
                    if scanner.isAtEnd {
                        throw ScholarOSError.bibliographyParseFailure(
                            format: "BibTeX",
                            line: entryLine,
                            detail: "Unexpected end of file inside @\(rawTypeName){\(citeKey), ...}."
                        )
                    }
                    if scanner.consumeIf(closeDelim) {
                        break
                    }
                    // Allow redundant commas
                    if scanner.consumeIf(",") {
                        continue
                    }

                    let fieldLine = scanner.line
                    let fieldName = scanner.readFieldOrMacroName()
                    guard !fieldName.isEmpty else {
                        throw ScholarOSError.bibliographyParseFailure(
                            format: "BibTeX",
                            line: fieldLine,
                            detail: "Expected field name or '\(closeDelim)' inside @\(rawTypeName){\(citeKey)}."
                        )
                    }

                    scanner.skipWhitespaceAndLineComments()
                    guard scanner.consumeIf("=") else {
                        throw ScholarOSError.bibliographyParseFailure(
                            format: "BibTeX",
                            line: scanner.line,
                            detail: "Expected '=' after field '\(fieldName)' in @\(rawTypeName){\(citeKey)}."
                        )
                    }

                    scanner.skipWhitespaceAndLineComments()
                    let fieldValue = try parseValueExpression(
                        scanner: &scanner,
                        macros: macros,
                        closingEntryDelimiter: closeDelim,
                        diagnostics: &diagnostics,
                        citeKeyContext: citeKey
                    )

                    let normalizedField = fieldName.lowercased()
                    if rawFields[normalizedField] == nil {
                        fieldOrder.append(normalizedField)
                    }
                    rawFields[normalizedField] = fieldValue

                    scanner.skipWhitespaceAndLineComments()
                    if scanner.consumeIf(",") {
                        continue
                    } else if scanner.consumeIf(closeDelim) {
                        break
                    } else {
                        throw ScholarOSError.bibliographyParseFailure(
                            format: "BibTeX",
                            line: scanner.line,
                            detail: "Expected ',' or '\(closeDelim)' after field '\(fieldName)' in @\(rawTypeName){\(citeKey)}."
                        )
                    }
                }
            }

            let (entry, unmapped) = buildBibliographyEntry(
                citeKey: citeKey,
                rawEntryType: lowerType,
                rawFields: rawFields,
                line: entryLine,
                diagnostics: &diagnostics
            )
            entries.append(entry)
            if !unmapped.isEmpty {
                unmappedByKey[citeKey] = unmapped
            }
        }

        return BibTeXDocument(
            preambles: preambles,
            macros: userMacros,
            comments: comments,
            entries: entries,
            unmappedFieldsByCiteKey: unmappedByKey,
            diagnostics: diagnostics
        )
    }

    public func serialize(_ entries: [BibliographyEntry]) -> String {
        let orderedEntries: [BibliographyEntry]
        if options.sortEntriesByCiteKey {
            orderedEntries = entries.sorted {
                $0.citeKey.localizedStandardCompare($1.citeKey) == .orderedAscending
            }
        } else {
            orderedEntries = entries
        }

        return orderedEntries
            .map { serializeEntry($0) }
            .joined(separator: "\n\n")
    }

    public func serializeDocument(_ document: BibTeXDocument) -> String {
        var blocks: [String] = []
        for preamble in document.preambles where !preamble.isEmpty {
            blocks.append("@preamble{{\(preamble)}}")
        }
        for key in document.macros.keys.sorted() {
            if let val = document.macros[key] {
                blocks.append("@string{\(key) = {\(val)}}")
            }
        }
        let serializedEntries = serialize(document.entries)
        if !serializedEntries.isEmpty {
            blocks.append(serializedEntries)
        }
        return blocks.joined(separator: "\n\n")
    }

    public func serializeEntry(_ entry: BibliographyEntry) -> String {
        let bibType = serializedBibTypeName(for: entry)
        var fields: [(String, String)] = []

        fields.append((
            "title",
            latexCodec.encode(
                entry.title,
                escapeUnicodeToLaTeX: options.escapeUnicodeToLaTeX,
                protectAcronymsInTitle: options.protectAcronymsInTitle
            )
        ))

        if !entry.authors.isEmpty {
            fields.append((
                "author",
                BibTeXAuthorParser.serializeAuthors(
                    entry.authors,
                    codec: latexCodec,
                    escapeUnicodeToLaTeX: options.escapeUnicodeToLaTeX
                )
            ))
            let orcids = entry.authors.compactMap(\.orcid)
            if !orcids.isEmpty && orcids.count == entry.authors.count {
                fields.append(("orcid", orcids.joined(separator: "; ")))
            }
        }

        if let year = entry.year {
            fields.append(("year", String(year)))
        }

        let trimmedVenue = entry.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVenue.isEmpty {
            let encodedVenue = latexCodec.encode(trimmedVenue, escapeUnicodeToLaTeX: options.escapeUnicodeToLaTeX)
            switch entry.kind {
            case .inproceedings, .incollection:
                fields.append(("booktitle", encodedVenue))
            case .phdthesis:
                fields.append(("school", encodedVenue))
            case .techreport:
                fields.append(("institution", encodedVenue))
            case .article, .book, .preprint, .misc:
                fields.append(("journal", encodedVenue))
            }
        }

        if let publisher = nonEmpty(entry.publisher) {
            fields.append(("publisher", latexCodec.encode(publisher, escapeUnicodeToLaTeX: options.escapeUnicodeToLaTeX)))
        }
        if let volume = nonEmpty(entry.volume) {
            fields.append(("volume", volume))
        }
        if let issue = nonEmpty(entry.issue) {
            fields.append(("number", issue))
        }
        if let pages = nonEmpty(entry.pages) {
            let normalizedPages = pages
                .replacingOccurrences(of: "–", with: "--")
                .replacingOccurrences(of: "—", with: "--")
            fields.append(("pages", normalizedPages))
        }
        if let doi = nonEmpty(entry.doi) {
            fields.append(("doi", doi))
        }
        if let arxivID = nonEmpty(entry.arxivID) {
            fields.append(("eprint", arxivID))
            fields.append(("archiveprefix", "arXiv"))
        }
        if let pmid = nonEmpty(entry.pmid) {
            fields.append(("pmid", pmid))
        }
        if let url = nonEmpty(entry.url) {
            fields.append(("url", url))
        }
        if let abstractText = nonEmpty(entry.abstractText) {
            fields.append(("abstract", latexCodec.encode(abstractText, escapeUnicodeToLaTeX: options.escapeUnicodeToLaTeX)))
        }
        if let pdfPath = nonEmpty(entry.attachedPDFPath) {
            fields.append(("file", ":\(pdfPath):PDF"))
        }

        if options.includeFirewallMetadataFields {
            fields.append(("x-firewall-class", entry.firewallClass.rawValue))
            if let note = nonEmpty(entry.firewallAuditNote) {
                fields.append(("x-firewall-note", latexCodec.encode(note, escapeUnicodeToLaTeX: options.escapeUnicodeToLaTeX)))
            }
        }

        if options.includeCitationGraphFields {
            if !entry.citedByKeys.isEmpty {
                fields.append(("x-cited-by", entry.citedByKeys.joined(separator: ", ")))
            }
            if !entry.referencesKeys.isEmpty {
                fields.append(("x-references", entry.referencesKeys.joined(separator: ", ")))
            }
        }

        var lines: [String] = []
        lines.reserveCapacity(fields.count + 2)
        lines.append("@\(bibType){\(entry.citeKey),")
        for (idx, pair) in fields.enumerated() {
            let paddingCount = max(1, options.alignEqualsColumn - pair.0.count - 2)
            let padding = String(repeating: " ", count: paddingCount)
            let trailingComma = (idx == fields.count - 1) ? "" : ","
            if pair.0 == "year" && pair.1.allSatisfy(\.isNumber) {
                lines.append("  \(pair.0)\(padding)= \(pair.1)\(trailingComma)")
            } else {
                lines.append("  \(pair.0)\(padding)= {\(pair.1)}\(trailingComma)")
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    public static func generateCiteKey(
        for entry: BibliographyEntry,
        existingKeys: Set<String> = []
    ) -> String {
        let rawSurname = entry.authors.first?.familyName ?? "anon"
        let asciiSurname = rawSurname
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let surnamePart = asciiSurname.isEmpty ? "anon" : asciiSurname

        let yearPart = entry.year.map(String.init) ?? "nd"

        let stopwords: Set<String> = [
            "a", "an", "the", "on", "of", "in", "for", "to", "with", "and", "or", "by", "from", "towards", "via", "using"
        ]
        let firstContentWord = entry.title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .first(where: { !stopwords.contains($0) && $0.count >= 2 }) ?? "work"

        let baseKey = "\(surnamePart)\(yearPart)\(firstContentWord)"
        if !existingKeys.contains(baseKey) {
            return baseKey
        }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for ch in letters {
            let candidate = "\(baseKey)_\(ch)"
            if !existingKeys.contains(candidate) {
                return candidate
            }
        }
        var suffix = 2
        while existingKeys.contains("\(baseKey)_\(suffix)") {
            suffix += 1
        }
        return "\(baseKey)_\(suffix)"
    }

    // MARK: - Private Value Expression & Field Mapping

    private func parseValueExpression(
        scanner: inout BibTeXScanner,
        macros: [String: String],
        closingEntryDelimiter: Character,
        diagnostics: inout [BibTeXParseDiagnostic],
        citeKeyContext: String?
    ) throws -> String {
        var pieces: [String] = []

        while true {
            scanner.skipWhitespaceAndLineComments()
            let tokenLine = scanner.line
            let tokenCol = scanner.column
            guard let next = scanner.peek() else {
                throw ScholarOSError.bibliographyParseFailure(
                    format: "BibTeX",
                    line: tokenLine,
                    detail: "Unexpected end of file while reading BibTeX field value."
                )
            }

            if next == "{" {
                scanner.advance()
                let braced = try scanner.readBalancedRawBody(closingDelimiter: "}", startLine: tokenLine)
                pieces.append(braced)
            } else if next == "\"" {
                scanner.advance()
                let quoted = try scanner.readQuotedValue(startLine: tokenLine)
                pieces.append(quoted)
            } else if next.isNumber || (next == "-" && scanner.peekNext()?.isNumber == true) {
                pieces.append(scanner.readNumericLiteral())
            } else {
                let ident = scanner.readFieldOrMacroName()
                guard !ident.isEmpty else {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: tokenLine,
                        detail: "Unexpected character '\(next)' in BibTeX value expression."
                    )
                }
                let lowerIdent = ident.lowercased()
                if let resolved = macros[lowerIdent] {
                    pieces.append(resolved)
                } else {
                    diagnostics.append(
                        BibTeXParseDiagnostic(
                            line: tokenLine,
                            column: tokenCol,
                            severity: .warning,
                            citeKey: citeKeyContext,
                            message: "Undefined @string macro '\(ident)'; using literal identifier."
                        )
                    )
                    pieces.append(ident)
                }
            }

            scanner.skipWhitespaceAndLineComments()
            if scanner.consumeIf("#") {
                continue
            } else {
                break
            }
        }

        _ = closingEntryDelimiter
        return pieces.joined()
    }

    private func buildBibliographyEntry(
        citeKey: String,
        rawEntryType: String,
        rawFields: [String: String],
        line: Int,
        diagnostics: inout [BibTeXParseDiagnostic]
    ) -> (BibliographyEntry, [String: String]) {
        var consumedKeys: Set<String> = []
        func take(_ keys: String...) -> String? {
            for k in keys {
                consumedKeys.insert(k)
                if let v = rawFields[k], !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return v.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }

        let rawTitle = take("title", "booktitle") ?? "Untitled"
        let decodedTitle = latexCodec.decode(rawTitle)

        let rawAuthor = take("author", "editor") ?? ""
        let rawORCID = take("orcid", "x-orcid")
        let authors = BibTeXAuthorParser.parseAuthors(rawAuthor, orcidField: rawORCID, codec: latexCodec)

        let yearInt: Int? = {
            if let yStr = take("year") {
                return extractFourDigitYear(from: latexCodec.decode(yStr))
            }
            if let dateStr = take("date") {
                return extractFourDigitYear(from: latexCodec.decode(dateStr))
            }
            return nil
        }()
        consumedKeys.insert("date")
        consumedKeys.insert("month")

        let rawJournal = take("journal", "journaltitle", "fjournal")
        let rawBooktitle = rawFields["title"] != nil ? take("booktitle", "maintitle", "eventtitle") : take("maintitle", "eventtitle")
        let rawSchool = take("school", "institution", "organization", "howpublished")
        let rawVenue = rawJournal ?? rawBooktitle ?? rawSchool ?? ""
        let decodedVenue = latexCodec.decode(rawVenue)

        let publisher = take("publisher").map { latexCodec.decode($0) }
        let volume = take("volume").map { latexCodec.decode($0) }
        let issue = take("number", "issue").map { latexCodec.decode($0) }
        let pages = take("pages", "eid", "articleno").map { normalizePageDash(latexCodec.decode($0)) }

        let rawDOI = take("doi")
        let cleanedDOI = cleanDOIField(rawDOI)

        let eprint = take("eprint")
        let eprintType = take("eprinttype", "archiveprefix")?.lowercased()
        let explicitArxiv = take("arxivid", "arxiv")
        let explicitPMID = take("pmid")
        let rawURL = take("url")

        var resolvedArxiv: String? = cleanArXivField(explicitArxiv)
        var resolvedPMID: String? = explicitPMID?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let eprint {
            if eprintType == "pubmed" || eprintType == "pmid" {
                if resolvedPMID == nil { resolvedPMID = eprint }
            } else if eprintType == "arxiv" || resolvedArxiv == nil && looksLikeArXivIdentifier(eprint) {
                resolvedArxiv = cleanArXivField(eprint)
            }
        }
        if resolvedArxiv == nil, let rawURL, let urlArxiv = extractArXivFromURL(rawURL) {
            resolvedArxiv = urlArxiv
        }
        if resolvedArxiv == nil, decodedVenue.lowercased().hasPrefix("arxiv:"), let vArxiv = cleanArXivField(decodedVenue) {
            resolvedArxiv = vArxiv
        }

        let abstractText = take("abstract").map { latexCodec.decode($0) }
        let attachedPDF = extractFileAttachmentPath(from: take("file", "pdf", "local-url"))

        let kind = mapEntryKind(
            rawType: rawEntryType,
            hasArxiv: resolvedArxiv != nil,
            hasJournalOrBooktitle: (rawJournal != nil || rawBooktitle != nil),
            venue: decodedVenue
        )

        var firewallClass: CitationFirewallClass = .unverifiedPendingCheck
        if let rawFW = take("x-firewall-class") {
            let decodedFW = latexCodec.decode(rawFW)
            if let matched = CitationFirewallClass(rawValue: decodedFW) {
                firewallClass = matched
            } else {
                diagnostics.append(
                    BibTeXParseDiagnostic(
                        line: line,
                        column: 1,
                        severity: .warning,
                        citeKey: citeKey,
                        message: "Unrecognized x-firewall-class '\(decodedFW)'; defaulting to UNVERIFIED_OFFLINE."
                    )
                )
            }
        }
        let firewallNote = take("x-firewall-note").map { latexCodec.decode($0) } ?? ""

        let citedByKeys = splitCitationKeyList(take("x-cited-by"))
        let referencesKeys = splitCitationKeyList(take("x-references", "cites"))

        var unmapped: [String: String] = [:]
        for (k, v) in rawFields where !consumedKeys.contains(k) {
            unmapped[k] = v
        }

        let entry = BibliographyEntry(
            citeKey: citeKey,
            kind: kind,
            title: decodedTitle,
            authors: authors,
            year: yearInt,
            venue: decodedVenue,
            publisher: publisher,
            volume: volume,
            issue: issue,
            pages: pages,
            doi: cleanedDOI,
            arxivID: resolvedArxiv,
            pmid: resolvedPMID,
            url: rawURL,
            abstractText: abstractText,
            firewallClass: firewallClass,
            firewallAuditNote: firewallNote,
            attachedPDFPath: attachedPDF,
            citedByKeys: citedByKeys,
            referencesKeys: referencesKeys
        )
        return (entry, unmapped)
    }

    private func mapEntryKind(
        rawType: String,
        hasArxiv: Bool,
        hasJournalOrBooktitle: Bool,
        venue: String
    ) -> BibEntryKind {
        switch rawType {
        case "article":
            let lowerVenue = venue.lowercased()
            if hasArxiv && (lowerVenue.isEmpty || lowerVenue.contains("arxiv") || lowerVenue.contains("corr")) {
                return .preprint
            }
            return .article
        case "inproceedings", "conference", "proceedings":
            return .inproceedings
        case "book", "mvbook", "collection":
            return .book
        case "incollection", "inbook", "suppbook":
            return .incollection
        case "phdthesis", "mastersthesis", "thesis":
            return .phdthesis
        case "techreport", "report", "manual":
            return .techreport
        case "preprint", "unpublished":
            return .preprint
        case "online", "electronic":
            return hasArxiv ? .preprint : .misc
        case "misc":
            return (hasArxiv && !hasJournalOrBooktitle) ? .preprint : .misc
        default:
            return .misc
        }
    }

    private func serializedBibTypeName(for entry: BibliographyEntry) -> String {
        switch entry.kind {
        case .article: return "article"
        case .inproceedings: return "inproceedings"
        case .book: return "book"
        case .incollection: return "incollection"
        case .phdthesis: return "phdthesis"
        case .techreport: return "techreport"
        case .preprint: return options.useBibLaTeXPreprintOnlineType ? "online" : "misc"
        case .misc: return "misc"
        }
    }

    private func extractFourDigitYear(from text: String) -> Int? {
        let chars = Array(text)
        if chars.count >= 4 {
            for start in 0...(chars.count - 4) {
                let slice = chars[start..<(start + 4)]
                if slice.allSatisfy(\.isNumber) {
                    let prevIsDigit = start > 0 && chars[start - 1].isNumber
                    let nextIsDigit = (start + 4 < chars.count) && chars[start + 4].isNumber
                    if !prevIsDigit && !nextIsDigit, let year = Int(String(slice)) {
                        return year
                    }
                }
            }
        }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func normalizePageDash(_ pages: String) -> String {
        pages
            .replacingOccurrences(of: "---", with: "–")
            .replacingOccurrences(of: "--", with: "–")
    }

    private func cleanDOIField(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        let prefixes = [
            "https://doi.org/", "http://doi.org/",
            "https://dx.doi.org/", "http://dx.doi.org/",
            "doi:", "DOI:"
        ]
        for prefix in prefixes where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func cleanArXivField(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if let urlExtracted = extractArXivFromURL(s) {
            return urlExtracted
        }
        if s.lowercased().hasPrefix("arxiv:") {
            s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? nil : s
    }

    private func extractArXivFromURL(_ url: String) -> String? {
        let lower = url.lowercased()
        for marker in ["arxiv.org/abs/", "arxiv.org/pdf/"] {
            if let range = lower.range(of: marker) {
                var id = String(url[range.upperBound...])
                if id.lowercased().hasSuffix(".pdf") {
                    id = String(id.dropLast(4))
                }
                id = id.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\r\n"))
                if !id.isEmpty { return id }
            }
        }
        return nil
    }

    private func looksLikeArXivIdentifier(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("/") { return true }
        let base = s.split(separator: "v").first.map(String.init) ?? s
        let parts = base.split(separator: ".")
        return parts.count == 2 && parts[0].count == 4 && parts[0].allSatisfy(\.isNumber)
            && (parts[1].count == 4 || parts[1].count == 5) && parts[1].allSatisfy(\.isNumber)
    }

    private func extractFileAttachmentPath(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // JabRef / Zotero format: `Description:/path/to/paper.pdf:PDF;Other:/other.pdf:PDF`
        let firstEntry = raw.split(separator: ";", omittingEmptySubsequences: true).first.map(String.init) ?? raw
        if firstEntry.contains(":") {
            let parts = firstEntry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3 {
                let candidate = parts[1].replacingOccurrences(of: "\\:", with: ":")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { return candidate }
            }
        }
        return firstEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitCitationKeyList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let t = value?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }
}

// MARK: - Low-Level Character Scanner with Line & Column Tracking

private struct BibTeXScanner {
    private let chars: [Character]
    private(set) var index: Int = 0
    private(set) var line: Int = 1
    private(set) var column: Int = 1

    init(source: String) {
        if source.hasPrefix("\u{FEFF}") {
            self.chars = Array(source.dropFirst())
        } else {
            self.chars = Array(source)
        }
    }

    var isAtEnd: Bool {
        index >= chars.count
    }

    func peek() -> Character? {
        index < chars.count ? chars[index] : nil
    }

    func peekNext() -> Character? {
        (index + 1) < chars.count ? chars[index + 1] : nil
    }

    mutating func advance() {
        guard index < chars.count else { return }
        if chars[index] == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index += 1
    }

    mutating func consumeIf(_ expected: Character) -> Bool {
        guard peek() == expected else { return false }
        advance()
        return true
    }

    mutating func skipWhitespaceAndLineComments() {
        while let ch = peek() {
            if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
                advance()
            } else if ch == "%" {
                while let c = peek(), c != "\n" {
                    advance()
                }
            } else {
                break
            }
        }
    }

    mutating func skipInterEntryTrivia(commentsSink: inout [String]) {
        var junkBuffer = ""
        while let ch = peek() {
            if ch == "@" {
                break
            }
            if ch == "%" {
                advance()
                let commentLine = readRestOfLine().trimmingCharacters(in: .whitespacesAndNewlines)
                if !commentLine.isEmpty {
                    commentsSink.append(commentLine)
                }
                continue
            }
            junkBuffer.append(ch)
            advance()
        }
        let trimmed = junkBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            commentsSink.append(trimmed)
        }
    }

    mutating func readRestOfLine() -> String {
        var out = ""
        while let ch = peek(), ch != "\n" {
            out.append(ch)
            advance()
        }
        _ = consumeIf("\n")
        return out
    }

    mutating func readIdentifier() -> String {
        var out = ""
        while let ch = peek(), (ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == ":") {
            out.append(ch)
            advance()
        }
        return out
    }

    mutating func readFieldOrMacroName() -> String {
        var out = ""
        while let ch = peek() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == ":" || ch == "." || ch == "/" || ch == "+" {
                out.append(ch)
                advance()
            } else {
                break
            }
        }
        return out
    }

    mutating func readCitationKey(closingDelimiter: Character) -> String {
        var out = ""
        while let ch = peek() {
            if ch == "," || ch == closingDelimiter || ch == " " || ch == "\t" || ch == "\r" || ch == "\n" {
                break
            }
            out.append(ch)
            advance()
        }
        return out
    }

    mutating func readNumericLiteral() -> String {
        var out = ""
        if consumeIf("-") {
            out.append("-")
        }
        while let ch = peek(), ch.isNumber {
            out.append(ch)
            advance()
        }
        return out
    }

    mutating func readBalancedRawBody(closingDelimiter: Character, startLine: Int) throws -> String {
        var out = ""
        var braceDepth = 0

        while let ch = peek() {
            if ch == "\\" {
                out.append(ch)
                advance()
                if let escaped = peek() {
                    out.append(escaped)
                    advance()
                }
                continue
            }

            if ch == "{" {
                braceDepth += 1
                out.append(ch)
                advance()
                continue
            }

            if ch == closingDelimiter && braceDepth == 0 {
                advance()
                return out
            }

            if ch == "}" {
                if braceDepth == 0 {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: line,
                        detail: "Unmatched '}' inside value starting at line \(startLine)."
                    )
                }
                braceDepth -= 1
                out.append(ch)
                advance()
                continue
            }

            out.append(ch)
            advance()
        }

        throw ScholarOSError.bibliographyParseFailure(
            format: "BibTeX",
            line: startLine,
            detail: "Unclosed BibTeX braced block; expected '\(closingDelimiter)' for block opened at line \(startLine)."
        )
    }

    mutating func readQuotedValue(startLine: Int) throws -> String {
        var out = ""
        var braceDepth = 0

        while let ch = peek() {
            if ch == "\\" {
                advance()
                guard let escaped = peek() else {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "BibTeX",
                        line: startLine,
                        detail: "Trailing backslash inside quoted BibTeX string opened at line \(startLine)."
                    )
                }
                if escaped == "\"" && braceDepth == 0 {
                    // Distinguish LaTeX umlaut `\"o` inside `"M\"uller"` from escaped literal quote `\"`
                    if let afterQuote = peekNext(), afterQuote.isLetter && hasClosingQuoteAheadOnEntry() {
                        out.append("\\\"")
                        advance()
                        continue
                    } else {
                        out.append("\"")
                        advance()
                        continue
                    }
                }
                out.append("\\")
                out.append(escaped)
                advance()
                continue
            }

            if ch == "{" {
                braceDepth += 1
                out.append(ch)
                advance()
                continue
            }
            if ch == "}" {
                if braceDepth > 0 {
                    braceDepth -= 1
                }
                out.append(ch)
                advance()
                continue
            }
            if ch == "\"" && braceDepth == 0 {
                advance()
                return out
            }

            out.append(ch)
            advance()
        }

        throw ScholarOSError.bibliographyParseFailure(
            format: "BibTeX",
            line: startLine,
            detail: "Unclosed quoted BibTeX value opened at line \(startLine)."
        )
    }

    private func hasClosingQuoteAheadOnEntry() -> Bool {
        var probe = index + 1
        while probe < chars.count {
            let c = chars[probe]
            if c == "\n" { return false }
            if c == "\"" && chars[probe - 1] != "\\" {
                return true
            }
            probe += 1
        }
        return false
    }
}
