import Darwin
import Foundation
import ScholarModels

// MARK: - M3 Stage 03: Verified BibTeX Entry Generation, Exact Deduplication & Locked O_APPEND Writer

public struct ChangedBibTeXField: Sendable, Codable, Hashable, Equatable {
    public let field: String
    public let given: String?
    public let written: String?
    public let source: String

    public init(field: String, given: String?, written: String?, source: String) {
        self.field = field
        self.given = given
        self.written = written
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case field
        case given
        case written
        case source
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(field, forKey: .field)
        if let given {
            try c.encode(given, forKey: .given)
        } else {
            try c.encodeNil(forKey: .given)
        }
        if let written {
            try c.encode(written, forKey: .written)
        } else {
            try c.encodeNil(forKey: .written)
        }
        try c.encode(source, forKey: .source)
    }
}

public struct GeneratedVerifiedBibTeX: Sendable, Codable, Hashable, Equatable {
    public let citeKey: String
    public let entryType: String
    public let bibtex: String
    public let changedFields: [ChangedBibTeXField]

    public init(
        citeKey: String,
        entryType: String,
        bibtex: String,
        changedFields: [ChangedBibTeXField]
    ) {
        self.citeKey = citeKey
        self.entryType = entryType
        self.bibtex = bibtex
        self.changedFields = changedFields
    }
}

public enum BibTeXDuplicateMatchKind: String, Sendable, Codable, Hashable, Equatable {
    case citeKey = "cite_key"
    case doi = "doi"
    case arxiv = "arxiv"
    case pmid = "pmid"
    case titleYearFirstAuthor = "title_year_first_author"
}

public enum BibTeXDuplicateCheckResult: Sendable, Hashable, Equatable {
    case allowAppend
    case skippedDuplicate(existingKey: String, matchedOn: BibTeXDuplicateMatchKind)
    case citeKeyConflict(citeKey: String, existingKey: String)
}

public enum VerifiedBibTeXWriteError: Error, LocalizedError, Sendable, Equatable {
    case invalidPath(path: String, reason: String)
    case encodingError(path: String, reason: String)
    case syntaxError(path: String, line: Int, startLine: Int, citeKey: String?, detail: String)
    case citeKeyConflict(citeKey: String, existingKey: String, path: String)
    case ioError(path: String, reason: String)

    public var errorCode: String {
        switch self {
        case .invalidPath:
            return "ERR_BIB_PATH"
        case .encodingError:
            return "ERR_BIB_ENCODING"
        case .syntaxError:
            return "ERR_BIB_SYNTAX"
        case .citeKeyConflict:
            return "ERR_CITE_KEY_CONFLICT"
        case .ioError:
            return "ERR_IO"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path, let reason):
            return "[ERR_BIB_PATH] \(path): \(reason)"
        case .encodingError(let path, let reason):
            return "[ERR_BIB_ENCODING] \(path): \(reason)"
        case .syntaxError(let path, let line, let startLine, let citeKey, let detail):
            if let citeKey, !citeKey.isEmpty {
                return "[ERR_BIB_SYNTAX] \(path):\(line) (entry '\(citeKey)', started at line \(startLine)): \(detail)"
            }
            return "[ERR_BIB_SYNTAX] \(path):\(line) (started at line \(startLine)): \(detail)"
        case .citeKeyConflict(let citeKey, let existingKey, let path):
            return "[ERR_CITE_KEY_CONFLICT] Citation key '\(citeKey)' conflicts with existing key '\(existingKey)' for a different work in \(path)."
        case .ioError(let path, let reason):
            return "[ERR_IO] \(path): \(reason)"
        }
    }
}

public enum VerifiedBibTeXAppendOutcome: Sendable, Hashable, Equatable {
    case appendedVerified(generated: GeneratedVerifiedBibTeX)
    case skippedDuplicate(existingKey: String, matchedOn: BibTeXDuplicateMatchKind)
}

public enum VerifiedBibTeXWriter {

    // MARK: - 1. Entry Type Mapping, HTML Decoding, Escaping & BibTeX Generation

    public static func isArXivOnlyRecord(_ record: RegistryWorkRecord) -> Bool {
        if record.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "arxiv" {
            return true
        }
        guard nonEmpty(record.arxivID) != nil else {
            return false
        }
        if let wt = nonEmpty(record.workType)?.lowercased(),
           (wt == "preprint" || wt == "posted-content") {
            return true
        }
        if let venue = nonEmpty(record.containerTitle) {
            return isArXivVenueName(venue)
        }
        return true
    }

    public static func mapWorkTypeToBibTeXEntryType(workType: String?, isArXivOnly: Bool) -> String {
        if isArXivOnly {
            return "misc"
        }
        guard let raw = nonEmpty(workType) else {
            return "misc"
        }
        let normalized = raw
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")

        switch normalized {
        case "journal-article", "article", "review", "review-article", "peer-review",
             "letter", "editorial", "erratum", "retraction", "book-review",
             "clinical-trial", "case-reports", "comparative-study", "meta-analysis",
             "systematic-review", "comment":
            return "article"
        case "proceedings-article", "proceedings", "conference-paper", "conference-abstract",
             "conference", "inproceedings", "congress":
            return "inproceedings"
        case "book", "monograph", "edited-book", "reference-book":
            return "book"
        case "book-chapter", "book-part", "book-section", "reference-entry",
             "incollection", "inbook":
            return "incollection"
        case "dissertation", "thesis", "phdthesis", "mastersthesis":
            return "phdthesis"
        case "report", "techreport", "technical-report", "standard", "working-paper":
            return "techreport"
        default:
            return "misc"
        }
    }

    /// Decodes HTML/XML character & named entities (up to two passes for double-encoded `&amp;amp;`)
    /// and collapses whitespace while preserving UTF-8 characters.
    public static func decodeHTMLEntities(_ text: String) -> String {
        var current = text
        for _ in 0..<2 {
            guard current.contains("&") else { break }
            let next = decodeHTMLEntitiesSinglePass(current)
            if next == current { break }
            current = next
        }
        return collapseWhitespace(current)
    }

    /// Escapes BibTeX/LaTeX special characters `& % $ # _` (without double-escaping already backslash-escaped tokens,
    /// while preserving balanced inline/display LaTeX math spans such as `$$e^ - \gamma \to ...$$` from Crossref)
    /// and leaves non-ASCII UTF-8 characters intact. Also escapes `{` / `}` only if braces in `text` are unbalanced.
    public static func escapeBibTeXSpecialCharacters(_ text: String) -> String {
        if text.isEmpty { return "" }
        let chars = Array(text)
        let bracesBalanced = hasBalancedBraces(chars)
        var out = ""
        out.reserveCapacity(chars.count + 8)

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "$", let (mathSpan, nextIndex) = tryConsumeBalancedLaTeXMathSpan(chars, from: i) {
                out.append(mathSpan)
                i = nextIndex
                continue
            }
            if ch == "\\" && i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "&" || next == "%" || next == "$" || next == "#" || next == "_" || next == "{" || next == "}" || next == "\\" {
                    out.append("\\")
                    out.append(next)
                    i += 2
                    continue
                }
                out.append("\\")
                i += 1
                continue
            }
            switch ch {
            case "&":
                out.append("\\&")
            case "%":
                out.append("\\%")
            case "$":
                out.append("\\$")
            case "#":
                out.append("\\#")
            case "_":
                out.append("\\_")
            case "{":
                out.append(bracesBalanced ? "{" : "\\{")
            case "}":
                out.append(bracesBalanced ? "}" : "\\}")
            default:
                out.append(ch)
            }
            i += 1
        }
        return out
    }

    public static func generateEntry(
        citeKey: String,
        record: RegistryWorkRecord,
        localEntry: BibliographyEntry,
        localUnmappedFields: [String: String] = [:]
    ) -> GeneratedVerifiedBibTeX {
        let trimmedKey = citeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = trimmedKey.isEmpty ? localEntry.citeKey : trimmedKey
        let arXivOnly = isArXivOnlyRecord(record)
        let entryType = mapWorkTypeToBibTeXEntryType(workType: record.workType, isArXivOnly: arXivOnly)

        var bibFields: [(String, String)] = []

        // 1. title (including subtitle via fullTitle)
        let plainTitle = nonEmpty(decodeHTMLEntities(record.fullTitle))
        var comparableTitle = plainTitle
        if let plainTitle {
            let escapedTitle = escapeBibTeXSpecialCharacters(plainTitle)
            bibFields.append(("title", escapedTitle))
            comparableTitle = nonEmpty(LaTeXTextCodec().decode(escapedTitle)) ?? plainTitle
        }

        // 2. author (all authors: Last, First; corporate authors enclosed in single outer braces)
        var writtenPlainAuthors: [BibAuthor] = []
        var serializedAuthorSegments: [String] = []
        for recAuthor in record.authors {
            if recAuthor.isCorporate {
                if let corp = nonEmpty(decodeHTMLEntities(recAuthor.name ?? recAuthor.familyName ?? "")) {
                    serializedAuthorSegments.append("{\(escapeBibTeXSpecialCharacters(corp))}")
                    writtenPlainAuthors.append(BibAuthor(givenName: "", familyName: corp))
                }
            } else {
                let fam = nonEmpty(decodeHTMLEntities(recAuthor.familyName ?? recAuthor.name ?? "")) ?? ""
                let giv = nonEmpty(decodeHTMLEntities(recAuthor.givenName ?? "")) ?? ""
                guard !fam.isEmpty || !giv.isEmpty else { continue }
                if fam.isEmpty {
                    serializedAuthorSegments.append("{\(escapeBibTeXSpecialCharacters(giv))}")
                    writtenPlainAuthors.append(BibAuthor(givenName: "", familyName: giv))
                } else if giv.isEmpty {
                    let escFam = escapeBibTeXSpecialCharacters(fam)
                    if fam.contains(" ") || fam.contains(",") {
                        serializedAuthorSegments.append("{\(escFam)}")
                    } else {
                        serializedAuthorSegments.append(escFam)
                    }
                    writtenPlainAuthors.append(BibAuthor(givenName: "", familyName: fam))
                } else {
                    let escFam = escapeBibTeXSpecialCharacters(fam)
                    let escGiv = escapeBibTeXSpecialCharacters(giv)
                    let safeFam = fam.contains(",") ? "{\(escFam)}" : escFam
                    serializedAuthorSegments.append("\(safeFam), \(escGiv)")
                    writtenPlainAuthors.append(BibAuthor(givenName: giv, familyName: fam))
                }
            }
        }
        if !serializedAuthorSegments.isEmpty {
            bibFields.append(("author", serializedAuthorSegments.joined(separator: " and ")))
        }

        // 3. year (match localEntry.year against record.publicationDates; fallback closest/first)
        let writtenYear = resolvePublicationYear(record: record, localYear: localEntry.year)
        if let writtenYear {
            bibFields.append(("year", String(writtenYear)))
        }

        // 4. journal or booktitle (suppress on arXiv-only, book, and "arXiv (Cornell University)")
        var writtenJournal: String? = nil
        var writtenBooktitle: String? = nil
        if !arXivOnly,
           let rawContainer = nonEmpty(record.containerTitle),
           !isArXivVenueName(rawContainer) {
            let decodedContainer = decodeHTMLEntities(rawContainer)
            if !decodedContainer.isEmpty && !isArXivVenueName(decodedContainer) {
                if entryType == "inproceedings" || entryType == "incollection" {
                    writtenBooktitle = decodedContainer
                    bibFields.append(("booktitle", escapeBibTeXSpecialCharacters(decodedContainer)))
                } else if entryType == "article" {
                    writtenJournal = decodedContainer
                    bibFields.append(("journal", escapeBibTeXSpecialCharacters(decodedContainer)))
                }
            }
        }

        // 5. volume, number, pages, publisher
        let plainVolume = nonEmpty(record.volume).flatMap { nonEmpty(decodeHTMLEntities($0)) }
        if let plainVolume {
            bibFields.append(("volume", escapeBibTeXSpecialCharacters(plainVolume)))
        }

        let plainNumber = nonEmpty(record.issue).flatMap { nonEmpty(decodeHTMLEntities($0)) }
        if let plainNumber {
            bibFields.append(("number", escapeBibTeXSpecialCharacters(plainNumber)))
        }

        let plainPages = nonEmpty(record.pages).flatMap { nonEmpty(decodeHTMLEntities($0)) }
        if let plainPages {
            bibFields.append(("pages", escapeBibTeXSpecialCharacters(plainPages)))
        }

        let plainPublisher: String? = {
            guard let rawPub = nonEmpty(record.publisher),
                  let decodedPub = nonEmpty(decodeHTMLEntities(rawPub))
            else {
                return nil
            }
            if arXivOnly && (decodedPub.lowercased() == "arxiv" || decodedPub.lowercased() == "cornell university") {
                return nil
            }
            return decodedPub
        }()
        if let plainPublisher {
            bibFields.append(("publisher", escapeBibTeXSpecialCharacters(plainPublisher)))
        }

        // 6. Identifiers: doi, eprint (+ archivePrefix + primaryClass), pmid (raw identifiers, no LaTeX underscore escaping)
        let plainDOI = nonEmpty(record.doi)
        if let plainDOI {
            bibFields.append(("doi", plainDOI))
        }

        let plainEprint = nonEmpty(record.arxivID)
        let plainArchivePrefix: String? = (plainEprint != nil) ? "arXiv" : nil
        let plainPrimaryClass: String? = (plainEprint != nil) ? nonEmpty(record.primaryCategory) : nil
        if let plainEprint {
            bibFields.append(("eprint", plainEprint))
            bibFields.append(("archivePrefix", "arXiv"))
            if let plainPrimaryClass {
                bibFields.append(("primaryClass", plainPrimaryClass))
            }
        }

        let plainPMID = nonEmpty(record.pmid)
        if let plainPMID {
            bibFields.append(("pmid", plainPMID))
        }

        // Format BibTeX entry text
        var lines: [String] = []
        lines.reserveCapacity(bibFields.count + 2)
        lines.append("@\(entryType){\(effectiveKey),")
        for (idx, pair) in bibFields.enumerated() {
            let comma = (idx == bibFields.count - 1) ? "" : ","
            lines.append("  \(pair.0) = {\(pair.1)}\(comma)")
        }
        lines.append("}")
        let bibtexString = lines.joined(separator: "\n")

        // Compute changed_fields between localEntry (+ localUnmappedFields) and written entry
        let changedFields = computeChangedFields(
            sourceName: record.source,
            localEntry: localEntry,
            localUnmappedFields: localUnmappedFields,
            writtenEntryType: entryType,
            writtenTitle: comparableTitle,
            writtenAuthors: writtenPlainAuthors,
            writtenYear: writtenYear,
            writtenJournal: writtenJournal,
            writtenBooktitle: writtenBooktitle,
            writtenVolume: plainVolume,
            writtenNumber: plainNumber,
            writtenPages: plainPages,
            writtenPublisher: plainPublisher,
            writtenDOI: plainDOI,
            writtenEprint: plainEprint,
            writtenArchivePrefix: plainArchivePrefix,
            writtenPrimaryClass: plainPrimaryClass,
            writtenPMID: plainPMID
        )

        return GeneratedVerifiedBibTeX(
            citeKey: effectiveKey,
            entryType: entryType,
            bibtex: bibtexString,
            changedFields: changedFields
        )
    }

    // MARK: - 2. Exact Deduplication (No Jaro-Winkler, No ReferenceDeduplicator)

    public static func checkDuplicate(
        citeKey: String,
        record: RegistryWorkRecord,
        localEntry: BibliographyEntry,
        existingEntries: [BibliographyEntry]
    ) -> BibTeXDuplicateCheckResult {
        let generated = generateEntry(citeKey: citeKey, record: record, localEntry: localEntry)
        let parsed = BibTeXCodec().parseDocumentRecovering(generated.bibtex)
        if let candidateEntry = parsed.entries.first {
            return checkDuplicate(candidate: candidateEntry, existingEntries: existingEntries)
        }
        let resolvedYear = resolvePublicationYear(record: record, localYear: localEntry.year)
        let fallback = BibliographyEntry(
            citeKey: citeKey,
            kind: localEntry.kind,
            title: decodeHTMLEntities(record.fullTitle),
            authors: localEntry.authors,
            year: resolvedYear,
            doi: record.doi,
            arxivID: record.arxivID,
            pmid: record.pmid
        )
        return checkDuplicate(candidate: fallback, existingEntries: existingEntries)
    }

    public static func checkDuplicate(
        candidate: BibliographyEntry,
        existingEntries: [BibliographyEntry]
    ) -> BibTeXDuplicateCheckResult {
        let candSig = DedupSignature(entry: candidate)

        // Step 1: Check case-insensitive citation key match first
        for existing in existingEntries {
            let existSig = DedupSignature(entry: existing)
            if !candSig.lowerKey.isEmpty && candSig.lowerKey == existSig.lowerKey {
                if isSameWork(candSig, existSig) != nil {
                    return .skippedDuplicate(existingKey: existing.citeKey, matchedOn: .citeKey)
                } else {
                    return .citeKeyConflict(citeKey: candidate.citeKey, existingKey: existing.citeKey)
                }
            }
        }

        // Step 2: Check whether the same paper is already in the file under another key
        for existing in existingEntries {
            let existSig = DedupSignature(entry: existing)
            if let matchKind = isSameWork(candSig, existSig) {
                return .skippedDuplicate(existingKey: existing.citeKey, matchedOn: matchKind)
            }
        }

        return .allowAppend
    }

    // MARK: - 3. Locked O_APPEND Writer

    public static func appendVerifiedEntry(
        toBibFileAtPath bibFilePath: String,
        citeKey: String,
        record: RegistryWorkRecord,
        localEntry: BibliographyEntry,
        localUnmappedFields: [String: String] = [:]
    ) throws -> VerifiedBibTeXAppendOutcome {
        try appendVerifiedEntryInternal(
            toBibFileAtPath: bibFilePath,
            citeKey: citeKey,
            record: record,
            localEntry: localEntry,
            localUnmappedFields: localUnmappedFields,
            postWriteVerificationHook: nil
        )
    }

    internal static func appendVerifiedEntryInternal(
        toBibFileAtPath bibFilePath: String,
        citeKey: String,
        record: RegistryWorkRecord,
        localEntry: BibliographyEntry,
        localUnmappedFields: [String: String] = [:],
        postWriteVerificationHook: ((Int32) -> Void)?
    ) throws -> VerifiedBibTeXAppendOutcome {
        try validateTargetBibPathBeforeOpen(bibFilePath)

        let generated = generateEntry(
            citeKey: citeKey,
            record: record,
            localEntry: localEntry,
            localUnmappedFields: localUnmappedFields
        )
        let generatedDoc = BibTeXCodec().parseDocumentRecovering(generated.bibtex)
        guard generatedDoc.errors.isEmpty, let candidateEntry = generatedDoc.entries.first else {
            throw VerifiedBibTeXWriteError.ioError(
                path: bibFilePath,
                reason: "Generated BibTeX failed internal round-trip validation."
            )
        }

        // Open existing regular .bib file or create a new one in an existing parent directory without following symlinks.
        let openFlags: Int32 = O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW
        let fd = Darwin.open(bibFilePath, openFlags, mode_t(0o644))
        if fd < 0 {
            let err = errno
            switch err {
            case ELOOP:
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: bibFilePath,
                    reason: "Symbolic links to .bib files are rejected."
                )
            case EISDIR:
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: bibFilePath,
                    reason: "Target path is a directory, not a regular .bib file."
                )
            case ENOENT, ENOTDIR:
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: bibFilePath,
                    reason: "Parent directory does not exist."
                )
            case EACCES, EPERM, EROFS:
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: bibFilePath,
                    reason: "Target .bib file or parent directory is not writable."
                )
            default:
                throw VerifiedBibTeXWriteError.ioError(
                    path: bibFilePath,
                    reason: String(cString: Darwin.strerror(err))
                )
            }
        }

        var isLocked = false
        defer {
            if isLocked {
                _ = flock(fd, LOCK_UN)
            }
            _ = Darwin.close(fd)
        }

        // Verify opened descriptor is a regular file
        var beforeStat = Darwin.stat()
        guard Darwin.fstat(fd, &beforeStat) == 0 else {
            let err = errno
            throw VerifiedBibTeXWriteError.ioError(path: bibFilePath, reason: String(cString: Darwin.strerror(err)))
        }
        guard (beforeStat.st_mode & S_IFMT) == S_IFREG else {
            throw VerifiedBibTeXWriteError.invalidPath(
                path: bibFilePath,
                reason: "Target descriptor is not a regular file."
            )
        }

        // Step 1: Exclusive lock (flock)
        while flock(fd, LOCK_EX) != 0 {
            let err = errno
            if err == EINTR { continue }
            throw VerifiedBibTeXWriteError.ioError(
                path: bibFilePath,
                reason: "flock(LOCK_EX) failed: \(String(cString: Darwin.strerror(err)))"
            )
        }
        isLocked = true

        // Re-stat inside lock and read exact current bytes from offset 0
        guard Darwin.fstat(fd, &beforeStat) == 0 else {
            let err = errno
            throw VerifiedBibTeXWriteError.ioError(path: bibFilePath, reason: String(cString: Darwin.strerror(err)))
        }
        let originalInode = beforeStat.st_ino
        let originalBytes = try readAllBytesFromOffsetZero(fd: fd, path: bibFilePath)
        let originalLength = originalBytes.count

        // Step 2a: Strict UTF-8 check inside lock
        if originalBytes.contains(0x00) {
            throw VerifiedBibTeXWriteError.encodingError(
                path: bibFilePath,
                reason: "Target .bib file contains NUL bytes and is not valid UTF-8 text."
            )
        }
        guard let existingText = String(data: originalBytes, encoding: .utf8) else {
            throw VerifiedBibTeXWriteError.encodingError(
                path: bibFilePath,
                reason: "Target .bib file is not valid UTF-8."
            )
        }

        // Step 2b: BibTeX syntax check (BIB001) inside lock
        let existingDoc = BibTeXCodec().parseDocumentRecovering(existingText)
        if let firstErr = existingDoc.errors.first {
            throw VerifiedBibTeXWriteError.syntaxError(
                path: bibFilePath,
                line: firstErr.line,
                startLine: firstErr.startLine,
                citeKey: firstErr.key,
                detail: firstErr.message
            )
        }

        // Step 2c: Deduplication check inside lock
        let dedupResult = checkDuplicate(candidate: candidateEntry, existingEntries: existingDoc.entries)
        switch dedupResult {
        case .skippedDuplicate(let existingKey, let matchedOn):
            return .skippedDuplicate(existingKey: existingKey, matchedOn: matchedOn)
        case .citeKeyConflict(let conflictKey, let existingKey):
            throw VerifiedBibTeXWriteError.citeKeyConflict(
                citeKey: conflictKey,
                existingKey: existingKey,
                path: bibFilePath
            )
        case .allowAppend:
            break
        }

        // Step 3–5: Match existing newline style (CRLF vs LF), prepend newline if missing at EOF, write via O_APPEND, fsync
        let newline = detectDominantLineEnding(in: originalBytes)
        let normalizedEntryText: String
        if newline == "\r\n" {
            normalizedEntryText = generated.bibtex
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
        } else {
            normalizedEntryText = generated.bibtex
        }

        let payloadString: String
        if originalBytes.isEmpty {
            payloadString = normalizedEntryText + newline
        } else if originalBytes.last != 0x0A {
            // Missing trailing newline at EOF: first complete the unterminated line with `newline`, then blank-line separator
            payloadString = newline + newline + normalizedEntryText + newline
        } else if endsWithBlankLine(originalBytes) {
            payloadString = normalizedEntryText + newline
        } else {
            payloadString = newline + normalizedEntryText + newline
        }

        let appendBytes = Data(payloadString.utf8)
        do {
            try writeAllBytes(fd: fd, data: appendBytes, path: bibFilePath)
            while Darwin.fsync(fd) != 0 {
                let err = errno
                if err == EINTR { continue }
                throw VerifiedBibTeXWriteError.ioError(
                    path: bibFilePath,
                    reason: "fsync failed: \(String(cString: Darwin.strerror(err)))"
                )
            }
        } catch {
            _ = Darwin.ftruncate(fd, off_t(originalLength))
            _ = Darwin.fsync(fd)
            throw error
        }

        postWriteVerificationHook?(fd)

        // Step 6: Verify inode unchanged and original bytes are an exact prefix of new file; rollback via ftruncate otherwise
        var afterStat = Darwin.stat()
        guard Darwin.fstat(fd, &afterStat) == 0 else {
            let err = errno
            _ = Darwin.ftruncate(fd, off_t(originalLength))
            _ = Darwin.fsync(fd)
            throw VerifiedBibTeXWriteError.ioError(path: bibFilePath, reason: String(cString: Darwin.strerror(err)))
        }
        if afterStat.st_ino != originalInode {
            _ = Darwin.ftruncate(fd, off_t(originalLength))
            _ = Darwin.fsync(fd)
            throw VerifiedBibTeXWriteError.ioError(
                path: bibFilePath,
                reason: "File inode unexpectedly changed during O_APPEND write."
            )
        }

        let updatedBytes = try readAllBytesFromOffsetZero(fd: fd, path: bibFilePath)
        guard updatedBytes.count == originalLength + appendBytes.count,
              updatedBytes.prefix(originalLength) == originalBytes
        else {
            _ = Darwin.ftruncate(fd, off_t(originalLength))
            _ = Darwin.fsync(fd)
            throw VerifiedBibTeXWriteError.ioError(
                path: bibFilePath,
                reason: "Post-write prefix verification failed; truncated back to original length."
            )
        }

        return .appendedVerified(generated: generated)
    }

    // MARK: - Private Path & POSIX I/O Helpers

    private static func validateTargetBibPathBeforeOpen(_ rawPath: String) throws {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VerifiedBibTeXWriteError.invalidPath(path: rawPath, reason: "Empty .bib path.")
        }
        if trimmed.hasSuffix("/") {
            throw VerifiedBibTeXWriteError.invalidPath(path: rawPath, reason: "Target path points to a directory.")
        }

        let nsPath = trimmed as NSString
        let lastComponent = nsPath.lastPathComponent
        let ext = (lastComponent as NSString).pathExtension.lowercased()
        let stem = (lastComponent as NSString).deletingPathExtension
        guard ext == "bib", !stem.isEmpty, stem != "." else {
            throw VerifiedBibTeXWriteError.invalidPath(
                path: rawPath,
                reason: "Target file must have a '.bib' extension."
            )
        }

        // Check parent directory exists and is a directory (never auto-create directories)
        let parentDir: String = {
            let dir = nsPath.deletingLastPathComponent
            return dir.isEmpty ? "." : dir
        }()
        var parentStat = Darwin.stat()
        guard stat(parentDir, &parentStat) == 0 else {
            throw VerifiedBibTeXWriteError.invalidPath(
                path: rawPath,
                reason: "Parent directory '\(parentDir)' does not exist."
            )
        }
        guard (parentStat.st_mode & S_IFMT) == S_IFDIR else {
            throw VerifiedBibTeXWriteError.invalidPath(
                path: rawPath,
                reason: "Parent path '\(parentDir)' is not a directory."
            )
        }

        // Check target with lstat (do NOT follow symlinks: reject symlinks per M3 Row 13)
        var targetStat = Darwin.stat()
        if Darwin.lstat(trimmed, &targetStat) == 0 {
            let modeType = targetStat.st_mode & S_IFMT
            if modeType == S_IFLNK {
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: rawPath,
                    reason: "Symbolic links to .bib files are rejected."
                )
            }
            if modeType == S_IFDIR {
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: rawPath,
                    reason: "Target path is a directory, not a regular .bib file."
                )
            }
            if modeType != S_IFREG {
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: rawPath,
                    reason: "Target path is not a regular file."
                )
            }
            if Darwin.access(trimmed, W_OK) != 0 {
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: rawPath,
                    reason: "Target .bib file is not writable."
                )
            }
        } else {
            let err = errno
            if err != ENOENT {
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: rawPath,
                    reason: String(cString: Darwin.strerror(err))
                )
            }
            if Darwin.access(parentDir, W_OK | X_OK) != 0 {
                throw VerifiedBibTeXWriteError.invalidPath(
                    path: rawPath,
                    reason: "Parent directory '\(parentDir)' is not writable."
                )
            }
        }
    }

    private static func readAllBytesFromOffsetZero(fd: Int32, path: String) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var offset: off_t = 0
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf -> ssize_t in
                guard let base = rawBuf.baseAddress else { return 0 }
                return Darwin.pread(fd, base, rawBuf.count, offset)
            }
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
                offset += off_t(bytesRead)
            } else if bytesRead == 0 {
                break
            } else {
                let err = errno
                if err == EINTR { continue }
                throw VerifiedBibTeXWriteError.ioError(
                    path: path,
                    reason: "pread failed: \(String(cString: Darwin.strerror(err)))"
                )
            }
        }
        return data
    }

    private static func writeAllBytes(fd: Int32, data: Data, path: String) throws {
        if data.isEmpty { return }
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var writtenTotal = 0
            while writtenTotal < rawBuf.count {
                let ptr = base.advanced(by: writtenTotal)
                let rc = Darwin.write(fd, ptr, rawBuf.count - writtenTotal)
                if rc > 0 {
                    writtenTotal += rc
                } else if rc < 0 && errno == EINTR {
                    continue
                } else {
                    let err = errno
                    throw VerifiedBibTeXWriteError.ioError(
                        path: path,
                        reason: "write failed: \(String(cString: Darwin.strerror(err)))"
                    )
                }
            }
        }
    }

    private static func detectDominantLineEnding(in data: Data) -> String {
        guard !data.isEmpty else { return "\n" }
        var crlfCount = 0
        var bareLFCount = 0
        var prevWasCR = false
        for byte in data {
            if byte == 0x0A {
                if prevWasCR {
                    crlfCount += 1
                } else {
                    bareLFCount += 1
                }
            }
            prevWasCR = (byte == 0x0D)
        }
        return (crlfCount > 0 && crlfCount >= bareLFCount) ? "\r\n" : "\n"
    }

    private static func endsWithBlankLine(_ data: Data) -> Bool {
        let count = data.count
        if count >= 4
            && data[count - 4] == 0x0D && data[count - 3] == 0x0A
            && data[count - 2] == 0x0D && data[count - 1] == 0x0A {
            return true
        }
        if count >= 2 && data[count - 2] == 0x0A && data[count - 1] == 0x0A {
            return true
        }
        return false
    }

    // MARK: - Private Deduplication Signature & Normalization Helpers (Self-Contained, No Jaro-Winkler)

    private struct DedupSignature {
        let lowerKey: String
        let normalizedDOI: String?
        let normalizedArXiv: String?
        let normalizedPMID: String?
        let normalizedTitle: String
        let year: Int?
        let normalizedFirstAuthor: String

        init(entry: BibliographyEntry) {
            self.lowerKey = entry.citeKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normDOI = VerifiedBibTeXWriter.normalizeDOIForDedup(entry.doi)
            let doiEmbeddedArXiv = normDOI.flatMap(VerifiedBibTeXWriter.extractArXivFromDataCiteDOI)
            self.normalizedDOI = normDOI
            self.normalizedArXiv = VerifiedBibTeXWriter.normalizeArXivIDForDedup(entry.arxivID) ?? doiEmbeddedArXiv
            self.normalizedPMID = VerifiedBibTeXWriter.normalizePMIDForDedup(entry.pmid)
            self.normalizedTitle = VerifiedBibTeXWriter.normalizeTitleForDedup(entry.title)
            self.year = entry.year
            self.normalizedFirstAuthor = VerifiedBibTeXWriter.normalizeFirstAuthorForDedup(entry.authors)
        }
    }

    private static func isSameWork(_ lhs: DedupSignature, _ rhs: DedupSignature) -> BibTeXDuplicateMatchKind? {
        // 1. Normalized DOI
        if let lDOI = lhs.normalizedDOI, let rDOI = rhs.normalizedDOI {
            if lDOI == rDOI {
                return .doi
            }
            if let lAx = lhs.normalizedArXiv, let rAx = rhs.normalizedArXiv, lAx == rAx {
                return .arxiv
            }
            return nil
        }

        // 2. Normalized arXiv ID
        if let lAx = lhs.normalizedArXiv, let rAx = rhs.normalizedArXiv {
            return (lAx == rAx) ? .arxiv : nil
        }

        // 3. Normalized PMID
        if let lPMID = lhs.normalizedPMID, let rPMID = rhs.normalizedPMID {
            return (lPMID == rPMID) ? .pmid : nil
        }

        // 4. Exact normalized (title + year + firstAuthor) all three simultaneously equal
        if !lhs.normalizedTitle.isEmpty,
           lhs.normalizedTitle == rhs.normalizedTitle,
           let lYear = lhs.year,
           let rYear = rhs.year,
           lYear == rYear,
           !lhs.normalizedFirstAuthor.isEmpty,
           lhs.normalizedFirstAuthor == rhs.normalizedFirstAuthor
        {
            return .titleYearFirstAuthor
        }

        return nil
    }

    private static func normalizeDOIForDedup(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if let decoded = s.removingPercentEncoding {
            s = decoded
        }
        let lowerCheck = s.lowercased()
        let prefixes = [
            "https://doi.org/",
            "http://doi.org/",
            "https://dx.doi.org/",
            "http://dx.doi.org/",
            "https://www.doi.org/",
            "http://www.doi.org/",
            "doi.org/",
            "dx.doi.org/",
            "doi:"
        ]
        for prefix in prefixes where lowerCheck.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        while let last = s.last, (last == "." || last == "," || last == ";" || last == " ") {
            s.removeLast()
        }
        let folded = s.lowercased()
        return folded.isEmpty ? nil : folded
    }

    private static func extractArXivFromDataCiteDOI(_ normalizedDOI: String) -> String? {
        guard normalizedDOI.hasPrefix("10.48550/arxiv.") else { return nil }
        let suffix = String(normalizedDOI.dropFirst("10.48550/arxiv.".count))
        return normalizeArXivIDForDedup(suffix)
    }

    private static func normalizeArXivIDForDedup(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        let lower = s.lowercased()
        for marker in ["arxiv.org/abs/", "arxiv.org/pdf/", "arxiv.org/html/"] {
            if let range = lower.range(of: marker) {
                s = String(s[range.upperBound...])
                break
            }
        }
        if s.lowercased().hasPrefix("arxiv:") {
            s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.lowercased().hasSuffix(".pdf") {
            s = String(s.dropLast(4))
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\r\n")).lowercased()
        guard !s.isEmpty else { return nil }

        // Strip trailing version `v\d+`
        if let vIdx = s.lastIndex(of: "v"), vIdx > s.startIndex {
            let verDigits = s[s.index(after: vIdx)...]
            if !verDigits.isEmpty && verDigits.allSatisfy(\.isNumber) {
                let base = String(s[..<vIdx])
                if base.contains(".") || base.contains("/") {
                    return base
                }
            }
        }
        return s
    }

    private static func normalizePMIDForDedup(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        let lower = s.lowercased()
        if let range = lower.range(of: "pubmed.ncbi.nlm.nih.gov/") {
            s = String(s[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        } else if lower.hasPrefix("pmid:") {
            s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.isEmpty, s.allSatisfy(\.isNumber) else { return nil }
        let strippedZeros = String(s.drop(while: { $0 == "0" }))
        return strippedZeros.isEmpty ? nil : strippedZeros
    }

    private static func normalizeTitleForDedup(_ rawTitle: String) -> String {
        let htmlDecoded = decodeHTMLEntities(rawTitle)
        let latexDecoded = LaTeXTextCodec().decode(htmlDecoded)
        let folded = foldDiacriticsAndLigatures(latexDecoded)
        return splitAlphanumericTokens(folded).joined(separator: " ")
    }

    private static func normalizeFirstAuthorForDedup(_ authors: [BibAuthor]) -> String {
        let realAuthors = authors.filter { author in
            let g = author.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            let f = author.familyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !(g.isEmpty && (f == "others" || f == "et al." || f == "et al"))
        }
        guard let first = realAuthors.first else { return "" }
        let rawSurnameOrCorp = first.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = rawSurnameOrCorp.isEmpty ? first.givenName : rawSurnameOrCorp
        let decoded = LaTeXTextCodec().decode(decodeHTMLEntities(target))
        let folded = foldDiacriticsAndLigatures(decoded)
        return splitAlphanumericTokens(folded).joined(separator: " ")
    }

    private static func foldDiacriticsAndLigatures(_ text: String) -> String {
        let ligatures = text
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ẞ", with: "ss")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "Æ", with: "ae")
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "Œ", with: "oe")
            .replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "Ø", with: "o")
            .replacingOccurrences(of: "ł", with: "l")
            .replacingOccurrences(of: "Ł", with: "l")
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
            .replacingOccurrences(of: "ı", with: "i")

        return ligatures.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func splitAlphanumericTokens(_ lowerText: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        for ch in lowerText {
            if ch.isLetter || ch.isNumber {
                cur.append(ch)
            } else if !cur.isEmpty {
                tokens.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty {
            tokens.append(cur)
        }
        return tokens
    }

    // MARK: - Private Generation & Changed-Fields Helpers

    private static func resolvePublicationYear(record: RegistryWorkRecord, localYear: Int?) -> Int? {
        let candidates = [
            record.publicationDates.publishedPrint?.year,
            record.publicationDates.publishedOnline?.year,
            record.publicationDates.issued?.year
        ].compactMap { $0 }

        guard !candidates.isEmpty else { return nil }
        if let localYear {
            if candidates.contains(localYear) {
                return localYear
            }
            return candidates.min(by: { abs($0 - localYear) < abs($1 - localYear) }) ?? candidates[0]
        }
        return candidates[0]
    }

    private static func computeChangedFields(
        sourceName: String,
        localEntry: BibliographyEntry,
        localUnmappedFields: [String: String],
        writtenEntryType: String,
        writtenTitle: String?,
        writtenAuthors: [BibAuthor],
        writtenYear: Int?,
        writtenJournal: String?,
        writtenBooktitle: String?,
        writtenVolume: String?,
        writtenNumber: String?,
        writtenPages: String?,
        writtenPublisher: String?,
        writtenDOI: String?,
        writtenEprint: String?,
        writtenArchivePrefix: String?,
        writtenPrimaryClass: String?,
        writtenPMID: String?
    ) -> [ChangedBibTeXField] {
        var diffs: [ChangedBibTeXField] = []

        func recordDiff(_ field: String, given: String?, written: String?) {
            if given != written {
                diffs.append(ChangedBibTeXField(field: field, given: given, written: written, source: sourceName))
            }
        }

        let localType: String = {
            switch localEntry.kind {
            case .article: return "article"
            case .inproceedings: return "inproceedings"
            case .book: return "book"
            case .incollection: return "incollection"
            case .phdthesis: return "phdthesis"
            case .techreport: return "techreport"
            case .preprint, .misc: return "misc"
            }
        }()
        recordDiff("entry_type", given: localType, written: writtenEntryType)
        recordDiff("title", given: nonEmpty(localEntry.title), written: writtenTitle)

        let localAuthorsFormatted = formatPlainAuthorsForDiff(localEntry.authors, truncated: localEntry.authorsTruncated)
        let writtenAuthorsFormatted = formatPlainAuthorsForDiff(writtenAuthors, truncated: false)
        recordDiff("author", given: localAuthorsFormatted, written: writtenAuthorsFormatted)

        recordDiff("year", given: localEntry.year.map(String.init), written: writtenYear.map(String.init))

        let localVenue = nonEmpty(localEntry.venue)
        var localJournal: String? = nil
        var localBooktitle: String? = nil
        var localSchool: String? = nil
        var localInstitution: String? = nil
        switch localEntry.kind {
        case .inproceedings, .incollection:
            localBooktitle = localVenue
        case .phdthesis:
            localSchool = localVenue
        case .techreport:
            localInstitution = localVenue
        case .article, .book, .preprint, .misc:
            localJournal = localVenue
        }
        recordDiff("journal", given: localJournal, written: writtenJournal)
        recordDiff("booktitle", given: localBooktitle, written: writtenBooktitle)
        recordDiff("school", given: localSchool, written: nil)
        recordDiff("institution", given: localInstitution, written: nil)

        recordDiff("volume", given: nonEmpty(localEntry.volume), written: writtenVolume)
        recordDiff("number", given: nonEmpty(localEntry.issue), written: writtenNumber)
        recordDiff("pages", given: nonEmpty(localEntry.pages), written: writtenPages)
        recordDiff("publisher", given: nonEmpty(localEntry.publisher), written: writtenPublisher)
        recordDiff("doi", given: nonEmpty(localEntry.doi), written: writtenDOI)
        recordDiff("eprint", given: nonEmpty(localEntry.arxivID), written: writtenEprint)
        recordDiff("archivePrefix", given: (nonEmpty(localEntry.arxivID) != nil ? "arXiv" : nil), written: writtenArchivePrefix)

        let localPrimaryClass = nonEmpty(localUnmappedFields["primaryclass"])
            .flatMap { nonEmpty(LaTeXTextCodec().decode($0)) }
        recordDiff("primaryClass", given: localPrimaryClass, written: writtenPrimaryClass)

        recordDiff("pmid", given: nonEmpty(localEntry.pmid), written: writtenPMID)
        recordDiff("url", given: nonEmpty(localEntry.url), written: nil)
        recordDiff("abstract", given: nonEmpty(localEntry.abstractText), written: nil)

        for key in localUnmappedFields.keys.sorted() where key != "primaryclass" {
            if let val = nonEmpty(localUnmappedFields[key]) {
                let decodedVal = nonEmpty(LaTeXTextCodec().decode(val)) ?? val
                recordDiff(key, given: decodedVal, written: nil)
            }
        }

        return diffs
    }

    private static func formatPlainAuthorsForDiff(_ authors: [BibAuthor], truncated: Bool) -> String? {
        var parts = authors.compactMap { author -> String? in
            let fam = author.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let giv = author.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
            if fam.isEmpty && giv.isEmpty { return nil }
            if giv.isEmpty {
                return (fam.lowercased() == "others" || fam.lowercased() == "et al.") ? "others" : fam
            }
            if fam.isEmpty { return giv }
            return "\(fam), \(giv)"
        }
        if truncated && parts.last != "others" {
            parts.append("others")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    private static func isArXivVenueName(_ name: String?) -> Bool {
        guard let lower = nonEmpty(name)?.lowercased() else { return false }
        return lower == "arxiv" || lower.hasPrefix("arxiv (") || lower.hasPrefix("arxiv:")
    }

    private static func hasBalancedBraces(_ chars: [Character]) -> Bool {
        var depth = 0
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" {
                i += 2
                continue
            }
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth < 0 { return false }
            }
            i += 1
        }
        return depth == 0
    }

    private static func tryConsumeBalancedLaTeXMathSpan(_ chars: [Character], from start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == "$" else { return nil }
        let isDisplay = (start + 1 < chars.count && chars[start + 1] == "$")
        let delimLen = isDisplay ? 2 : 1
        let bodyStart = start + delimLen
        guard bodyStart < chars.count else { return nil }

        var cursor = bodyStart
        while cursor < chars.count {
            if chars[cursor] == "\\" {
                cursor += 2
                continue
            }
            if isDisplay {
                if cursor + 1 < chars.count && chars[cursor] == "$" && chars[cursor + 1] == "$" {
                    let inner = Array(chars[bodyStart..<cursor])
                    if containsLaTeXMathConstruct(inner) && hasBalancedBraces(inner) {
                        return (String(chars[start..<(cursor + 2)]), cursor + 2)
                    }
                    return nil
                }
            } else if chars[cursor] == "$" {
                if cursor + 1 < chars.count && chars[cursor + 1] == "$" {
                    return nil
                }
                let inner = Array(chars[bodyStart..<cursor])
                if containsLaTeXMathConstruct(inner) && hasBalancedBraces(inner) {
                    return (String(chars[start..<(cursor + 1)]), cursor + 1)
                }
                return nil
            }
            cursor += 1
        }
        return nil
    }

    private static func containsLaTeXMathConstruct(_ inner: [Character]) -> Bool {
        guard !inner.isEmpty else { return false }
        for idx in inner.indices {
            let c = inner[idx]
            if c == "^" || c == "_" {
                return true
            }
            if c == "\\" && idx + 1 < inner.count && inner[idx + 1].isLetter {
                return true
            }
        }
        return false
    }

    private static func decodeHTMLEntitiesSinglePass(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let ch = text[cursor]
            if ch != "&" {
                out.append(ch)
                cursor = text.index(after: cursor)
                continue
            }
            let entityStart = text.index(after: cursor)
            var scan = entityStart
            var steps = 0
            var foundSemi: String.Index?
            while scan < text.endIndex && steps < 16 {
                let sCh = text[scan]
                if sCh == ";" {
                    foundSemi = scan
                    break
                }
                if sCh == "&" || sCh.isWhitespace {
                    break
                }
                scan = text.index(after: scan)
                steps += 1
            }
            if let semiIdx = foundSemi, semiIdx > entityStart {
                let token = String(text[entityStart..<semiIdx])
                if let resolved = resolveHTMLEntity(token) {
                    out.append(resolved)
                    cursor = text.index(after: semiIdx)
                    continue
                }
            }
            out.append("&")
            cursor = entityStart
        }
        return out
    }

    private static func resolveHTMLEntity(_ token: String) -> String? {
        if token.hasPrefix("#x") || token.hasPrefix("#X") {
            let hex = token.dropFirst(2)
            guard !hex.isEmpty, hex.count <= 6, hex.allSatisfy(\.isHexDigit),
                  let cp = UInt32(hex, radix: 16), cp > 0,
                  let scalar = UnicodeScalar(cp) else {
                return nil
            }
            return (cp == 0x0D || cp == 0x0A) ? " " : String(scalar)
        }
        if token.hasPrefix("#") {
            let dec = token.dropFirst(1)
            guard !dec.isEmpty, dec.count <= 7, dec.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let cp = UInt32(dec, radix: 10), cp > 0,
                  let scalar = UnicodeScalar(cp) else {
                return nil
            }
            return (cp == 0x0D || cp == 0x0A) ? " " : String(scalar)
        }
        switch token.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "ndash": return "–"
        case "mdash": return "—"
        case "ldquo": return "“"
        case "rdquo": return "”"
        case "lsquo": return "‘"
        case "rsquo": return "’"
        case "hellip": return "…"
        case "times": return "×"
        case "minus": return "−"
        case "deg": return "°"
        case "pm", "plusmn": return "±"
        case "alpha": return "α"
        case "beta": return "β"
        case "gamma": return "γ"
        case "delta": return "δ"
        case "epsilon": return "ε"
        case "mu": return "μ"
        case "omega": return "ω"
        default: return nil
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
