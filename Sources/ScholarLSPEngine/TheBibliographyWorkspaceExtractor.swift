import Foundation
import ScholarBibAndCSL
import ScholarMarkupAST
import ScholarModels

/// Extracted `\bibitem` entry along with its exact source span inside a `.tex` or `.bbl` file.
public struct ExtractedTheBibliographyItem: Sendable, Hashable {
    public let entry: BibliographyEntry
    public let optionalLabel: String?
    public let declarationSpan: TextSpan

    public init(entry: BibliographyEntry, optionalLabel: String?, declarationSpan: TextSpan) {
        self.entry = entry
        self.optionalLabel = optionalLabel
        self.declarationSpan = declarationSpan
    }
}

/// Extraction result for a single manuscript `.tex` or `.bbl` file.
public struct TheBibliographyExtractionResult: Sendable, Hashable {
    public let filePath: String
    public let sourceKind: String
    public let hasTheBibliographyEnvironment: Bool
    public let items: [ExtractedTheBibliographyItem]

    public var uniqueEntries: [BibliographyEntry] {
        var seenLower: Set<String> = []
        var out: [BibliographyEntry] = []
        out.reserveCapacity(items.count)
        for item in items {
            let lower = item.entry.citeKey.lowercased()
            if seenLower.insert(lower).inserted {
                out.append(item.entry)
            }
        }
        return out
    }

    public var uniqueEntryCount: Int {
        Set(items.map { $0.entry.citeKey.lowercased() }).count
    }
}

/// Token-driven extractor for `thebibliography` environments across `.tex` documents,
/// `\input{*.bbl}` files, and `<main>.bbl` fallback files.
/// Because it operates on `IncrementalMarkupLexer` tokens, `%` comments, `\verb`, `verbatim`,
/// `lstlisting`, `minted`, `comment` environments, and `\iffalse…\fi` blocks are automatically skipped.
public enum TheBibliographyWorkspaceExtractor {

    private static let macroDefiners: Set<String> = [
        "\\newcommand", "\\newcommand*", "\\renewcommand", "\\renewcommand*",
        "\\providecommand", "\\providecommand*", "\\DeclareRobustCommand", "\\DeclareRobustCommand*",
        "\\NewDocumentCommand", "\\RenewDocumentCommand", "\\ProvideDocumentCommand", "\\DeclareDocumentCommand",
        "\\def", "\\gdef", "\\edef", "\\xdef", "\\let", "\\futurelet"
    ]

    public static func extract(
        fromSource source: String,
        filePath: String,
        lexer: IncrementalMarkupLexer = IncrementalMarkupLexer(configuration: .losslessCST)
    ) -> TheBibliographyExtractionResult {
        let tokens = lexer.tokenize(source: source, format: .latex, filePath: filePath)
        return extract(fromTokens: tokens, filePath: filePath)
    }

    public static func extract(
        fromTokens tokens: [MarkupToken],
        filePath: String
    ) -> TheBibliographyExtractionResult {
        let sourceKind = filePath.lowercased().hasSuffix(".bbl") ? "bbl" : "thebibliography"
        let entryParser = TheBibliographyEntryParser()
        let count = tokens.count
        var idx = 0
        var hasEnv = false
        var items: [ExtractedTheBibliographyItem] = []

        func skipWhitespaceAndComments(_ cursor: inout Int) {
            while cursor < count && tokens[cursor].kind != .eof {
                let k = tokens[cursor].kind
                if k == .whitespace || k == .comment {
                    cursor += 1
                } else {
                    break
                }
            }
        }

        func readBracedText(_ cursor: inout Int) -> (text: String, endPos: TextPosition)? {
            guard cursor < count, tokens[cursor].kind == .leftBrace else { return nil }
            var depth = 1
            var endPos = tokens[cursor].span.end
            cursor += 1
            var parts: [String] = []
            while cursor < count && tokens[cursor].kind != .eof && depth > 0 {
                let tok = tokens[cursor]
                endPos = tok.span.end
                if tok.kind == .comment {
                    cursor += 1
                    continue
                }
                if tok.kind == .leftBrace {
                    depth += 1
                    parts.append(tok.lexeme)
                } else if tok.kind == .rightBrace {
                    depth -= 1
                    if depth > 0 {
                        parts.append(tok.lexeme)
                    }
                } else {
                    parts.append(tok.lexeme)
                }
                cursor += 1
            }
            return (parts.joined(), endPos)
        }

        func readOptionalBracketLabel(_ cursor: inout Int) -> String? {
            guard cursor < count, tokens[cursor].kind == .leftBracket else { return nil }
            var bracketDepth = 1
            var braceDepth = 0
            cursor += 1
            var parts: [String] = []
            while cursor < count && tokens[cursor].kind != .eof && bracketDepth > 0 {
                let tok = tokens[cursor]
                if tok.kind == .comment {
                    cursor += 1
                    continue
                }
                if tok.kind == .leftBrace {
                    braceDepth += 1
                    parts.append(tok.lexeme)
                } else if tok.kind == .rightBrace {
                    if braceDepth > 0 {
                        braceDepth -= 1
                    }
                    parts.append(tok.lexeme)
                } else if braceDepth == 0 && tok.kind == .leftBracket {
                    bracketDepth += 1
                    parts.append(tok.lexeme)
                } else if braceDepth == 0 && tok.kind == .rightBracket {
                    bracketDepth -= 1
                    if bracketDepth > 0 {
                        parts.append(tok.lexeme)
                    }
                } else {
                    parts.append(tok.lexeme)
                }
                cursor += 1
            }
            return parts.joined()
        }

        func matchEnvironmentBoundary(at pos: Int, commandLexeme: String) -> (envName: String, afterBraceIndex: Int)? {
            guard pos < count,
                  tokens[pos].kind == .command,
                  tokens[pos].lexeme == commandLexeme
            else {
                return nil
            }
            var cursor = pos + 1
            skipWhitespaceAndComments(&cursor)
            guard let (rawEnv, _) = readBracedText(&cursor) else {
                return nil
            }
            return (rawEnv.trimmingCharacters(in: .whitespacesAndNewlines), cursor)
        }

        func isPrecededByMacroDefiner(at pos: Int) -> Bool {
            var back = pos - 1
            while back >= 0 {
                let t = tokens[back]
                if t.kind == .whitespace || t.kind == .comment {
                    back -= 1
                    continue
                }
                if t.lexeme == "=" {
                    back -= 1
                    continue
                }
                if t.kind == .leftBrace {
                    back -= 1
                    while back >= 0 && (tokens[back].kind == .whitespace || tokens[back].kind == .comment) {
                        back -= 1
                    }
                }
                if back >= 0 && tokens[back].kind == .command && macroDefiners.contains(tokens[back].lexeme) {
                    return true
                }
                return false
            }
            return false
        }

        func skipOutsideMacroReplacementBody(_ cursor: inout Int, definerLexeme: String) {
            cursor += 1
            if definerLexeme == "\\let" || definerLexeme == "\\futurelet" {
                skipWhitespaceAndComments(&cursor)
                if cursor < count { cursor += 1 }
                skipWhitespaceAndComments(&cursor)
                if cursor < count && tokens[cursor].lexeme == "=" {
                    cursor += 1
                    skipWhitespaceAndComments(&cursor)
                }
                if cursor < count { cursor += 1 }
                return
            }
            // Skip macro name (`{\cmd}` or `\cmd`) + parameter spec (`[1]`, `#1#2`, etc.) + `{replacement}`
            skipWhitespaceAndComments(&cursor)
            if cursor < count && tokens[cursor].kind == .leftBrace {
                _ = readBracedText(&cursor)
            } else if cursor < count && tokens[cursor].kind == .command {
                cursor += 1
            }
            while cursor < count && tokens[cursor].kind != .eof {
                skipWhitespaceAndComments(&cursor)
                guard cursor < count else { break }
                if tokens[cursor].kind == .leftBracket {
                    _ = readOptionalBracketLabel(&cursor)
                    continue
                }
                if tokens[cursor].kind == .leftBrace {
                    _ = readBracedText(&cursor)
                    break
                }
                if tokens[cursor].lexeme.hasPrefix("#") || tokens[cursor].kind == .textWord {
                    cursor += 1
                    continue
                }
                break
            }
        }

        while idx < count && tokens[idx].kind != .eof {
            let tok = tokens[idx]
            if tok.kind == .command && macroDefiners.contains(tok.lexeme) {
                skipOutsideMacroReplacementBody(&idx, definerLexeme: tok.lexeme)
                continue
            }

            if let (envName, afterBegin) = matchEnvironmentBoundary(at: idx, commandLexeme: "\\begin"),
               envName == "thebibliography" {
                hasEnv = true
                idx = afterBegin
                // Consume optional `[...]` and mandatory `{widest_label}` header arguments of `thebibliography`
                skipWhitespaceAndComments(&idx)
                if idx < count && tokens[idx].kind == .leftBracket {
                    _ = readOptionalBracketLabel(&idx)
                    skipWhitespaceAndComments(&idx)
                }
                if idx < count && tokens[idx].kind == .leftBrace {
                    _ = readBracedText(&idx)
                }

                var envDepth = 1
                while idx < count && tokens[idx].kind != .eof && envDepth > 0 {
                    if let (innerBegin, nextAfterBegin) = matchEnvironmentBoundary(at: idx, commandLexeme: "\\begin"),
                       innerBegin == "thebibliography",
                       !isPrecededByMacroDefiner(at: idx) {
                        envDepth += 1
                        idx = nextAfterBegin
                        continue
                    }
                    if let (innerEnd, nextAfterEnd) = matchEnvironmentBoundary(at: idx, commandLexeme: "\\end"),
                       innerEnd == "thebibliography",
                       !isPrecededByMacroDefiner(at: idx) {
                        envDepth -= 1
                        idx = nextAfterEnd
                        continue
                    }

                    let curTok = tokens[idx]
                    if curTok.kind == .command && macroDefiners.contains(curTok.lexeme) {
                        skipOutsideMacroReplacementBody(&idx, definerLexeme: curTok.lexeme)
                        continue
                    }

                    if curTok.kind == .command && curTok.lexeme == "\\bibitem" && !isPrecededByMacroDefiner(at: idx) {
                        let startPos = curTok.span.start
                        var endPos = curTok.span.end
                        idx += 1
                        skipWhitespaceAndComments(&idx)

                        let optLabel: String?
                        if idx < count && tokens[idx].kind == .leftBracket {
                            optLabel = readOptionalBracketLabel(&idx)
                            skipWhitespaceAndComments(&idx)
                        } else {
                            optLabel = nil
                        }

                        var rawKey = ""
                        if idx < count && tokens[idx].kind == .leftBrace {
                            if let bracedKey = readBracedText(&idx) {
                                rawKey = bracedKey.text
                                endPos = bracedKey.endPos
                            }
                        } else if idx < count && tokens[idx].kind != .eof {
                            let nextLex = tokens[idx].lexeme
                            if nextLex != "\\bibitem" && nextLex != "\\end" {
                                rawKey = nextLex
                                endPos = tokens[idx].span.end
                                idx += 1
                            }
                        }

                        let normalizedKey = LaTeXKeyNormalizer.normalize(rawKey)
                        var bodyParts: [String] = []
                        while idx < count && tokens[idx].kind != .eof {
                            if tokens[idx].kind == .command
                                && tokens[idx].lexeme == "\\bibitem"
                                && !isPrecededByMacroDefiner(at: idx) {
                                break
                            }
                            if let (endName, _) = matchEnvironmentBoundary(at: idx, commandLexeme: "\\end"),
                               endName == "thebibliography",
                               !isPrecededByMacroDefiner(at: idx) {
                                break
                            }
                            if tokens[idx].kind != .comment {
                                bodyParts.append(tokens[idx].lexeme)
                            }
                            idx += 1
                        }

                        if !normalizedKey.isEmpty {
                            let rawBody = bodyParts.joined()
                            let parsedEntry = entryParser.parseEntry(
                                citeKey: normalizedKey,
                                optionalLabel: optLabel,
                                rawBody: rawBody
                            )
                            let declSpan = TextSpan(filePath: filePath, start: startPos, end: endPos)
                            items.append(
                                ExtractedTheBibliographyItem(
                                    entry: parsedEntry,
                                    optionalLabel: optLabel,
                                    declarationSpan: declSpan
                                )
                            )
                        }
                        continue
                    }

                    idx += 1
                }
                continue
            }

            idx += 1
        }

        return TheBibliographyExtractionResult(
            filePath: filePath,
            sourceKind: sourceKind,
            hasTheBibliographyEnvironment: hasEnv,
            items: items
        )
    }
}
