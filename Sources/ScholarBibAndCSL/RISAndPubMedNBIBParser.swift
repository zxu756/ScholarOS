import Foundation
import ScholarModels

// MARK: - RIS Export Configuration

public struct RISExportOptions: Sendable, Codable, Hashable {
    public var lineEnding: String
    public var includeAbstract: Bool
    public var includeFirewallMetadataNote: Bool
    public var includePDFAttachmentTag: Bool
    public var includeCitationGraphNotes: Bool

    public init(
        lineEnding: String = "\n",
        includeAbstract: Bool = true,
        includeFirewallMetadataNote: Bool = true,
        includePDFAttachmentTag: Bool = true,
        includeCitationGraphNotes: Bool = true
    ) {
        self.lineEnding = lineEnding
        self.includeAbstract = includeAbstract
        self.includeFirewallMetadataNote = includeFirewallMetadataNote
        self.includePDFAttachmentTag = includePDFAttachmentTag
        self.includeCitationGraphNotes = includeCitationGraphNotes
    }

    public static let standard = RISExportOptions()
    public static let windowsEndNoteCRLF = RISExportOptions(lineEnding: "\r\n")
}

// MARK: - Research Information Systems (RIS) Parser & Exporter (EndNote / Zotero / Scopus / WoS)

public struct RISParser: Sendable {

    public let strictMode: Bool
    public let exportOptions: RISExportOptions

    private static let firewallNotePrefix = "[ScholarOS-Firewall:"

    public init(
        strictMode: Bool = false,
        exportOptions: RISExportOptions = .standard
    ) {
        self.strictMode = strictMode
        self.exportOptions = exportOptions
    }

    // MARK: - Parse RIS Records

    public func parse(_ source: String) throws -> [BibliographyEntry] {
        let normalizedSource = stripUTF8BOM(source)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalizedSource.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [BibliographyEntry] = []
        var usedKeys: Set<String> = []

        var currentRecord: MutableRISRecord?
        var lastTag: String?

        for (zeroIndex, rawLine) in lines.enumerated() {
            let lineNumber = zeroIndex + 1
            let trimmedRight = rawLine.replacingOccurrences(
                of: "\\s+$",
                with: "",
                options: .regularExpression
            )

            if trimmedRight.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }

            if let (tag, payload) = matchRISTagLine(trimmedRight) {
                if tag == "TY" {
                    // If previous record was never closed by ER, finalize or fail in strict mode
                    if let unfinished = currentRecord {
                        if strictMode {
                            throw ScholarOSError.bibliographyParseFailure(
                                format: "RIS",
                                line: lineNumber,
                                detail: "Encountered new 'TY  -' record before closing previous record (started at line \(unfinished.startLine)) with 'ER  -'."
                            )
                        }
                        let built = finalizeRecord(unfinished, usedKeys: &usedKeys)
                        entries.append(built)
                    }
                    currentRecord = MutableRISRecord(startLine: lineNumber, rawTypeCode: payload)
                    lastTag = "TY"
                    continue
                }

                if tag == "ER" {
                    guard let finished = currentRecord else {
                        if strictMode {
                            throw ScholarOSError.bibliographyParseFailure(
                                format: "RIS",
                                line: lineNumber,
                                detail: "Encountered 'ER  -' end-of-record tag without a matching 'TY  -' header."
                            )
                        }
                        continue
                    }
                    let built = finalizeRecord(finished, usedKeys: &usedKeys)
                    entries.append(built)
                    currentRecord = nil
                    lastTag = nil
                    continue
                }

                if currentRecord == nil {
                    if strictMode {
                        throw ScholarOSError.bibliographyParseFailure(
                            format: "RIS",
                            line: lineNumber,
                            detail: "RIS tag '\(tag)  -' appeared outside a 'TY  -' ... 'ER  -' record."
                        )
                    }
                    currentRecord = MutableRISRecord(startLine: lineNumber, rawTypeCode: "GEN")
                }

                currentRecord?.appendTag(tag, value: payload)
                lastTag = tag
            } else {
                // Continuation line (common in EndNote/Scopus multi-line abstracts & notes)
                if var active = currentRecord, let previousTag = lastTag {
                    let continuationText = trimmedRight.trimmingCharacters(in: .whitespaces)
                    active.appendContinuation(for: previousTag, continuation: continuationText)
                    currentRecord = active
                } else if strictMode {
                    throw ScholarOSError.bibliographyParseFailure(
                        format: "RIS",
                        line: lineNumber,
                        detail: "Unrecognized RIS line syntax: '\(trimmedRight)'."
                    )
                }
            }
        }

        if let trailing = currentRecord {
            if strictMode {
                throw ScholarOSError.bibliographyParseFailure(
                    format: "RIS",
                    line: lines.count,
                    detail: "RIS record opened at line \(trailing.startLine) is missing closing 'ER  -' tag."
                )
            }
            entries.append(finalizeRecord(trailing, usedKeys: &usedKeys))
        }

        return entries
    }

    // MARK: - Export RIS Records (EndNote / Zotero Handoff)

    public func export(_ entries: [BibliographyEntry]) -> String {
        entries
            .map { exportEntry($0) }
            .joined(separator: exportOptions.lineEnding + exportOptions.lineEnding)
    }

    public func serialize(_ entries: [BibliographyEntry]) -> String {
        export(entries)
    }

    public func exportEntry(_ entry: BibliographyEntry) -> String {
        var lines: [String] = []
        lines.reserveCapacity(18)

        lines.append("TY  - \(risTypeCode(for: entry.kind))")
        lines.append("ID  - \(entry.citeKey)")
        lines.append("TI  - \(sanitizeSingleLine(entry.title))")

        for author in entry.authors {
            if author.givenName.isEmpty {
                lines.append("AU  - \(sanitizeSingleLine(author.familyName))")
            } else {
                lines.append("AU  - \(sanitizeSingleLine(author.familyName)), \(sanitizeSingleLine(author.givenName))")
            }
        }

        let cleanVenue = entry.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanVenue.isEmpty {
            switch entry.kind {
            case .article:
                lines.append("T2  - \(sanitizeSingleLine(cleanVenue))")
                lines.append("JF  - \(sanitizeSingleLine(cleanVenue))")
            case .inproceedings, .incollection:
                lines.append("T2  - \(sanitizeSingleLine(cleanVenue))")
            case .phdthesis, .techreport:
                lines.append("PB  - \(sanitizeSingleLine(cleanVenue))")
            case .book, .preprint, .misc:
                lines.append("T2  - \(sanitizeSingleLine(cleanVenue))")
            }
        }

        if let publisher = nonEmpty(entry.publisher),
           !(entry.kind == .phdthesis || entry.kind == .techreport && publisher == cleanVenue) {
            lines.append("PB  - \(sanitizeSingleLine(publisher))")
        }

        if let year = entry.year {
            lines.append("PY  - \(year)")
        }

        if let volume = nonEmpty(entry.volume) {
            lines.append("VL  - \(sanitizeSingleLine(volume))")
        }

        if let issue = nonEmpty(entry.issue) {
            lines.append("IS  - \(sanitizeSingleLine(issue))")
        }

        if let pages = nonEmpty(entry.pages) {
            let (startPage, endPage) = splitPageRange(pages)
            if !startPage.isEmpty {
                lines.append("SP  - \(startPage)")
            }
            if let ep = endPage, !ep.isEmpty {
                lines.append("EP  - \(ep)")
            }
        }

        if let doi = nonEmpty(entry.doi) {
            lines.append("DO  - \(sanitizeSingleLine(doi))")
        }

        if let arxivID = nonEmpty(entry.arxivID) {
            lines.append("AN  - arXiv:\(sanitizeSingleLine(arxivID))")
        }

        if let pmid = nonEmpty(entry.pmid) {
            lines.append("C2  - PMID:\(sanitizeSingleLine(pmid))")
        }

        if let url = nonEmpty(entry.url) {
            lines.append("UR  - \(sanitizeSingleLine(url))")
        } else if let doi = nonEmpty(entry.doi) {
            lines.append("UR  - https://doi.org/\(sanitizeSingleLine(doi))")
        } else if let arxiv = nonEmpty(entry.arxivID) {
            lines.append("UR  - https://arxiv.org/abs/\(sanitizeSingleLine(arxiv))")
        }

        if exportOptions.includePDFAttachmentTag, let pdfPath = nonEmpty(entry.attachedPDFPath) {
            if pdfPath.hasPrefix("file://") {
                lines.append("L1  - \(sanitizeSingleLine(pdfPath))")
            } else {
                lines.append("L1  - file://\(sanitizeSingleLine(pdfPath))")
            }
        }

        if exportOptions.includeAbstract, let abstractText = nonEmpty(entry.abstractText) {
            lines.append("AB  - \(sanitizeSingleLine(abstractText))")
        }

        if exportOptions.includeFirewallMetadataNote {
            let noteTail = entry.firewallAuditNote.isEmpty ? "" : " \(sanitizeSingleLine(entry.firewallAuditNote))"
            lines.append("N1  - \(Self.firewallNotePrefix) \(entry.firewallClass.rawValue)]\(noteTail)")
        }

        if exportOptions.includeCitationGraphNotes {
            if !entry.citedByKeys.isEmpty {
                lines.append("N1  - [ScholarOS-CitedBy: \(entry.citedByKeys.joined(separator: ", "))]")
            }
            if !entry.referencesKeys.isEmpty {
                lines.append("N1  - [ScholarOS-References: \(entry.referencesKeys.joined(separator: ", "))]")
            }
        }

        for author in entry.authors {
            if let orcid = nonEmpty(author.orcid) {
                lines.append("N1  - [ScholarOS-ORCID: \(author.familyName)=\(orcid)]")
            }
        }

        lines.append("ER  - ")
        return lines.joined(separator: exportOptions.lineEnding)
    }

    // MARK: - Private RIS Parsing Helpers

    private struct MutableRISRecord {
        let startLine: Int
        var rawTypeCode: String
        var tags: [String: [String]] = [:]

        mutating func appendTag(_ tag: String, value: String) {
            tags[tag, default: []].append(value.trimmingCharacters(in: .whitespaces))
        }

        mutating func appendContinuation(for tag: String, continuation: String) {
            guard !continuation.isEmpty else { return }
            if var list = tags[tag], !list.isEmpty {
                let lastIdx = list.count - 1
                list[lastIdx] = list[lastIdx].isEmpty ? continuation : "\(list[lastIdx]) \(continuation)"
                tags[tag] = list
            } else {
                tags[tag] = [continuation]
            }
        }

        func first(_ candidates: String...) -> String? {
            for key in candidates {
                if let vals = tags[key] {
                    for v in vals {
                        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                }
            }
            return nil
        }

        func all(_ candidates: String...) -> [String] {
            var collected: [String] = []
            for key in candidates {
                if let vals = tags[key] {
                    for v in vals {
                        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { collected.append(trimmed) }
                    }
                }
            }
            return collected
        }
    }

    private func matchRISTagLine(_ line: String) -> (String, String)? {
        let chars = Array(line)
        guard chars.count >= 5 else { return nil }
        let c0 = chars[0]
        let c1 = chars[1]
        guard (c0.isUppercase || c0.isNumber), (c1.isUppercase || c1.isNumber) else {
            return nil
        }
        // Standard RIS: `XX  - value` or `XX  -` (at end of line for `ER  -`)
        if chars[2] == " " && chars[3] == " " && chars[4] == "-" {
            let tag = String([c0, c1])
            if chars.count == 5 {
                return (tag, "")
            }
            if chars[5] == " " {
                let payload = chars.count > 6 ? String(chars[6...]) : ""
                return (tag, payload.trimmingCharacters(in: .whitespaces))
            } else {
                let payload = String(chars[5...])
                return (tag, payload.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func finalizeRecord(_ record: MutableRISRecord, usedKeys: inout Set<String>) -> BibliographyEntry {
        let kind = mapRISType(record.rawTypeCode)
        let title = record.first("TI", "T1", "CT", "BT") ?? "Untitled"

        let notes = record.all("N1", "RN")
        let orcidBySurname = parseORCIDNotes(notes)

        let rawAuthors = record.all("AU", "A1", "A2", "A3", "A4")
        let authors: [BibAuthor] = rawAuthors.compactMap { rawName in
            parseRISAuthor(rawName, orcidBySurname: orcidBySurname)
        }

        let year = extractYearFromRISDate(record.first("PY", "Y1", "DA", "Y2"))
        let venue = record.first("T2", "JF", "JO", "JA", "J2", "BT") ?? ""
        let publisher = record.first("PB")
        let volume = record.first("VL")
        let issue = record.first("IS", "M1")

        let pages: String? = {
            let sp = record.first("SP")
            let ep = record.first("EP")
            if let sp, let ep, !ep.isEmpty, sp != ep {
                return "\(sp)–\(ep)"
            }
            return sp ?? ep
        }()

        var doi = normalizeIdentifierPrefix(record.first("DO"))
        if doi == nil, let m3 = record.first("M3"), m3.contains("10.") {
            doi = normalizeIdentifierPrefix(m3)
        }

        var arxivID: String?
        var pmid: String?

        for acc in record.all("AN", "C2", "M1") {
            let lower = acc.lowercased()
            if lower.hasPrefix("arxiv:") {
                arxivID = String(acc.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("pmid:") {
                pmid = String(acc.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if pmid == nil && acc.allSatisfy(\.isNumber) && acc.count >= 5 && acc.count <= 9 {
                pmid = acc
            }
        }

        let url = record.first("UR", "L2", "LK")
        if arxivID == nil, let url, let extracted = extractArXivFromURL(url) {
            arxivID = extracted
        }

        let attachedPDFPath = decodeLocalAttachmentPath(record.first("L1"))
        let abstractText = record.first("AB", "N2")

        let (firewallClass, firewallNote) = parseFirewallNote(notes)
        let citedByKeys = parseBracketedKeyList(notes, prefix: "[ScholarOS-CitedBy:")
        let referencesKeys = parseBracketedKeyList(notes, prefix: "[ScholarOS-References:")

        let resolvedKind: BibEntryKind = (kind == .misc && arxivID != nil && venue.isEmpty) ? .preprint : kind

        var provisionalEntry = BibliographyEntry(
            citeKey: record.first("ID") ?? "",
            kind: resolvedKind,
            title: title,
            authors: authors,
            year: year,
            venue: venue,
            publisher: publisher,
            volume: volume,
            issue: issue,
            pages: pages,
            doi: doi,
            arxivID: arxivID,
            pmid: pmid,
            url: url,
            abstractText: abstractText,
            firewallClass: firewallClass,
            firewallAuditNote: firewallNote,
            attachedPDFPath: attachedPDFPath,
            citedByKeys: citedByKeys,
            referencesKeys: referencesKeys
        )

        let finalKey: String
        if let explicitID = record.first("ID"), !explicitID.isEmpty, !usedKeys.contains(explicitID) {
            finalKey = sanitizeCiteKey(explicitID, existingKeys: usedKeys)
        } else {
            finalKey = BibTeXCodec.generateCiteKey(for: provisionalEntry, existingKeys: usedKeys)
        }
        usedKeys.insert(finalKey)

        provisionalEntry = BibliographyEntry(
            citeKey: finalKey,
            kind: provisionalEntry.kind,
            title: provisionalEntry.title,
            authors: provisionalEntry.authors,
            year: provisionalEntry.year,
            venue: provisionalEntry.venue,
            publisher: provisionalEntry.publisher,
            volume: provisionalEntry.volume,
            issue: provisionalEntry.issue,
            pages: provisionalEntry.pages,
            doi: provisionalEntry.doi,
            arxivID: provisionalEntry.arxivID,
            pmid: provisionalEntry.pmid,
            url: provisionalEntry.url,
            abstractText: provisionalEntry.abstractText,
            firewallClass: provisionalEntry.firewallClass,
            firewallAuditNote: provisionalEntry.firewallAuditNote,
            attachedPDFPath: provisionalEntry.attachedPDFPath,
            citedByKeys: provisionalEntry.citedByKeys,
            referencesKeys: provisionalEntry.referencesKeys
        )
        return provisionalEntry
    }

    private func mapRISType(_ rawCode: String) -> BibEntryKind {
        switch rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "JOUR", "JFULL", "ABST", "MGZN", "NEWS":
            return .article
        case "CONF", "CPAPER":
            return .inproceedings
        case "BOOK", "EDBOOK":
            return .book
        case "CHAP", "SECT":
            return .incollection
        case "THES":
            return .phdthesis
        case "RPRT", "STAND", "GOVDOC":
            return .techreport
        case "UNPB", "MANSCPT", "PREPRINT", "INPR":
            return .preprint
        default:
            return .misc
        }
    }

    private func risTypeCode(for kind: BibEntryKind) -> String {
        switch kind {
        case .article: return "JOUR"
        case .inproceedings: return "CONF"
        case .book: return "BOOK"
        case .incollection: return "CHAP"
        case .phdthesis: return "THES"
        case .techreport: return "RPRT"
        case .preprint: return "UNPB"
        case .misc: return "GEN"
        }
    }

    private func parseRISAuthor(_ raw: String, orcidBySurname: [String: String]) -> BibAuthor? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if parts.count >= 2 {
            let family = parts[0]
            let given = parts.count >= 3 && !parts[2].isEmpty
                ? "\(parts[1]) (\(parts[2]))"
                : parts[1]
            return BibAuthor(
                givenName: parts[1],
                familyName: parts.count >= 3 && !parts[2].isEmpty ? "\(family), \(parts[2])" : family,
                orcid: orcidBySurname[family]
            )
            .normalizedAuthorSuffix(givenOverride: given, rawParts: parts, orcid: orcidBySurname[family])
        }

        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 1 {
            return BibAuthor(givenName: "", familyName: words[0], orcid: orcidBySurname[words[0]])
        }
        let family = words.last ?? trimmed
        let given = words.dropLast().joined(separator: " ")
        return BibAuthor(givenName: given, familyName: family, orcid: orcidBySurname[family])
    }

    private func extractYearFromRISDate(_ rawDate: String?) -> Int? {
        guard let rawDate, !rawDate.isEmpty else { return nil }
        // Standard RIS PY format: `2017/12/04/` or `2017`
        if let slashPrefix = rawDate.split(separator: "/").first,
           slashPrefix.count == 4,
           let y = Int(slashPrefix) {
            return y
        }
        let chars = Array(rawDate)
        if chars.count >= 4 {
            for i in 0...(chars.count - 4) {
                let sub = chars[i..<(i + 4)]
                if sub.allSatisfy(\.isNumber), let y = Int(String(sub)) {
                    return y
                }
            }
        }
        return nil
    }

    private func splitPageRange(_ pages: String) -> (String, String?) {
        let unified = pages
            .replacingOccurrences(of: "---", with: "–")
            .replacingOccurrences(of: "--", with: "–")
            .replacingOccurrences(of: "-", with: "–")
        let parts = unified.split(separator: "–", maxSplits: 1, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 {
            return (parts[0], parts[1])
        }
        return (pages.trimmingCharacters(in: .whitespaces), nil)
    }

    private func normalizeIdentifierPrefix(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "doi:", "DOI:"] {
            if s.hasPrefix(prefix) {
                s.removeFirst(prefix.count)
                break
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func extractArXivFromURL(_ url: String) -> String? {
        let lower = url.lowercased()
        for marker in ["arxiv.org/abs/", "arxiv.org/pdf/"] {
            if let r = lower.range(of: marker) {
                var id = String(url[r.upperBound...])
                if id.lowercased().hasSuffix(".pdf") {
                    id = String(id.dropLast(4))
                }
                id = id.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\r\n"))
                if !id.isEmpty { return id }
            }
        }
        return nil
    }

    private func decodeLocalAttachmentPath(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("file://") {
            if let fileURL = URL(string: s), fileURL.isFileURL {
                return fileURL.path
            }
            s.removeFirst("file://".count)
        }
        return s.removingPercentEncoding ?? s
    }

    private func parseFirewallNote(_ notes: [String]) -> (CitationFirewallClass, String) {
        for note in notes where note.hasPrefix(Self.firewallNotePrefix) {
            if let closeBracket = note.firstIndex(of: "]") {
                let codeStart = note.index(note.startIndex, offsetBy: Self.firewallNotePrefix.count)
                let rawStatus = String(note[codeStart..<closeBracket]).trimmingCharacters(in: .whitespaces)
                let auditTail = String(note[note.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
                if let fw = CitationFirewallClass(rawValue: rawStatus) {
                    return (fw, auditTail)
                }
            }
        }
        return (.unverified, "")
    }

    private func parseORCIDNotes(_ notes: [String]) -> [String: String] {
        let prefix = "[ScholarOS-ORCID:"
        var map: [String: String] = [:]
        for note in notes where note.hasPrefix(prefix) && note.hasSuffix("]") {
            let inner = String(note.dropFirst(prefix.count).dropLast()).trimmingCharacters(in: .whitespaces)
            let kv = inner.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                map[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return map
    }

    private func parseBracketedKeyList(_ notes: [String], prefix: String) -> [String] {
        for note in notes where note.hasPrefix(prefix) && note.hasSuffix("]") {
            let inner = String(note.dropFirst(prefix.count).dropLast())
            return inner
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func sanitizeCiteKey(_ key: String, existingKeys: Set<String>) -> String {
        let cleaned = key.filter { !$0.isWhitespace && $0 != "," && $0 != "{" && $0 != "}" }
        guard !cleaned.isEmpty else { return "record\(existingKeys.count + 1)" }
        if !existingKeys.contains(cleaned) { return cleaned }
        var idx = 2
        while existingKeys.contains("\(cleaned)_\(idx)") {
            idx += 1
        }
        return "\(cleaned)_\(idx)"
    }

    private func sanitizeSingleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripUTF8BOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}

private extension BibAuthor {
    func normalizedAuthorSuffix(givenOverride: String, rawParts: [String], orcid: String?) -> BibAuthor {
        _ = givenOverride
        if rawParts.count >= 3 && !rawParts[2].isEmpty {
            return BibAuthor(givenName: rawParts[1], familyName: "\(rawParts[0]), \(rawParts[2])", orcid: orcid)
        }
        return BibAuthor(givenName: rawParts[1], familyName: rawParts[0], orcid: orcid)
    }
}

// MARK: - NCBI PubMed / MEDLINE (.nbib) Parser & Exporter

public struct PubMedNBIBParser: Sendable {

    public let strictMode: Bool

    public init(strictMode: Bool = false) {
        self.strictMode = strictMode
    }

    // MARK: - Parse PubMed MEDLINE .nbib

    public func parse(_ source: String) throws -> [BibliographyEntry] {
        let normalized = (source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var entries: [BibliographyEntry] = []
        var usedKeys: Set<String> = []

        var currentRecord: MutableNBIBRecord?

        for (zeroIndex, rawLine) in lines.enumerated() {
            let lineNumber = zeroIndex + 1

            // Blank line separates multi-record PubMed exports
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                if let completed = currentRecord, completed.hasContent {
                    entries.append(finalizeNBIBRecord(completed, usedKeys: &usedKeys))
                    currentRecord = nil
                }
                continue
            }

            // Indented continuation line (standard MEDLINE uses 6 spaces, tolerate >= 2 leading spaces/tabs)
            if rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t") {
                guard var active = currentRecord, active.lastTag != nil else {
                    if strictMode {
                        throw ScholarOSError.bibliographyParseFailure(
                            format: "NBIB",
                            line: lineNumber,
                            detail: "Indented continuation line appeared before any MEDLINE tag."
                        )
                    }
                    continue
                }
                active.appendContinuation(rawLine.trimmingCharacters(in: .whitespaces))
                currentRecord = active
                continue
            }

            if let (tag, value) = matchNBIBTagLine(rawLine) {
                // If a second PMID- starts without an intervening blank line, flush prior record
                if tag == "PMID", let existing = currentRecord, existing.tags["PMID"] != nil {
                    entries.append(finalizeNBIBRecord(existing, usedKeys: &usedKeys))
                    currentRecord = MutableNBIBRecord(startLine: lineNumber)
                } else if currentRecord == nil {
                    currentRecord = MutableNBIBRecord(startLine: lineNumber)
                }

                currentRecord?.appendTag(tag, value: value)
            } else if strictMode {
                throw ScholarOSError.bibliographyParseFailure(
                    format: "NBIB",
                    line: lineNumber,
                    detail: "Malformed PubMed/MEDLINE tag line: '\(rawLine)'."
                )
            }
        }

        if let trailing = currentRecord, trailing.hasContent {
            entries.append(finalizeNBIBRecord(trailing, usedKeys: &usedKeys))
        }

        return entries
    }

    // MARK: - Export PubMed MEDLINE .nbib

    public func export(_ entries: [BibliographyEntry]) -> String {
        entries.map { exportEntry($0) }.joined(separator: "\n\n")
    }

    public func exportEntry(_ entry: BibliographyEntry) -> String {
        var lines: [String] = []
        if let pmid = entry.pmid, !pmid.isEmpty {
            lines.append("PMID- \(pmid)")
        }
        lines.append("OWN - NLM")
        lines.append("STAT- MEDLINE")
        if let year = entry.year {
            lines.append("DP  - \(year)")
        }
        for wrapped in wrapNBIBField(tag: "TI", value: entry.title) {
            lines.append(wrapped)
        }
        if let pages = entry.pages, !pages.isEmpty {
            lines.append("PG  - \(pages.replacingOccurrences(of: "–", with: "-"))")
        }
        if let doi = entry.doi, !doi.isEmpty {
            lines.append("LID - \(doi) [doi]")
        }
        if let arxiv = entry.arxivID, !arxiv.isEmpty {
            lines.append("LID - \(arxiv) [arxiv]")
        }
        if let abstractText = entry.abstractText, !abstractText.isEmpty {
            for wrapped in wrapNBIBField(tag: "AB", value: abstractText) {
                lines.append(wrapped)
            }
        }
        for author in entry.authors {
            if author.givenName.isEmpty {
                lines.append("CN  - \(author.familyName)")
            } else {
                lines.append("FAU - \(author.familyName), \(author.givenName)")
                let initials = author.givenName
                    .split(whereSeparator: { $0 == " " || $0 == "-" })
                    .compactMap(\.first)
                    .map(String.init)
                    .joined()
                lines.append("AU  - \(author.familyName) \(initials)")
                if let orcid = author.orcid, !orcid.isEmpty {
                    lines.append("AUID- ORCID: \(orcid)")
                }
            }
        }
        let publicationType: String = {
            switch entry.kind {
            case .article: return "Journal Article"
            case .inproceedings: return "Congress"
            case .book, .incollection: return "Book"
            case .phdthesis: return "Academic Dissertation"
            case .techreport: return "Technical Report"
            case .preprint: return "Preprint"
            case .misc: return "Journal Article"
            }
        }()
        lines.append("PT  - \(publicationType)")
        if !entry.venue.isEmpty {
            lines.append("JT  - \(entry.venue)")
        }
        if let volume = entry.volume, !volume.isEmpty {
            lines.append("VI  - \(volume)")
        }
        if let issue = entry.issue, !issue.isEmpty {
            lines.append("IP  - \(issue)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Canonical MEDLINE Abbreviated Page Expansion

    /// Expands NLM/MEDLINE truncated page ranges (`5998-608` -> `5998–6008`, `124-9` -> `124–129`, `S12-8` -> `S12–S18`).
    public static func expandMedlinePageRange(_ rawPages: String) -> String {
        let trimmed = rawPages.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Handle comma-separated discontinuous page segments (`12-5, 21`)
        if trimmed.contains(",") {
            return trimmed
                .split(separator: ",")
                .map { expandMedlinePageRange(String($0)) }
                .joined(separator: ", ")
        }

        let normalized = trimmed
            .replacingOccurrences(of: "--", with: "-")
            .replacingOccurrences(of: "–", with: "-")

        let parts = normalized.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return trimmed }

        let startStr = parts[0]
        let endStr = parts[1]
        guard !startStr.isEmpty, !endStr.isEmpty else { return trimmed }

        let (startPrefix, startDigits) = splitAlphaNumericPage(startStr)
        let (endPrefix, endDigits) = splitAlphaNumericPage(endStr)

        if !startDigits.isEmpty && !endDigits.isEmpty && endDigits.count < startDigits.count && (endPrefix.isEmpty || endPrefix == startPrefix) {
            let inheritedCount = startDigits.count - endDigits.count
            let inherited = String(startDigits.prefix(inheritedCount))
            let expandedEndDigits = inherited + endDigits
            if let sVal = Int(startDigits), let eVal = Int(expandedEndDigits), eVal >= sVal {
                return "\(startPrefix)\(startDigits)–\(startPrefix)\(expandedEndDigits)"
            }
        }

        return "\(startStr)–\(endStr)"
    }

    // MARK: - Private NBIB Record State & Builders

    private struct AuthorBuilder {
        var fullAuthor: String?
        var shortAuthor: String?
        var orcid: String?
        var isCorporate: Bool = false
    }

    private struct MutableNBIBRecord {
        let startLine: Int
        var tags: [String: [String]] = [:]
        var authorBuilders: [AuthorBuilder] = []
        var lastTag: String?

        var hasContent: Bool {
            !tags.isEmpty || !authorBuilders.isEmpty
        }

        mutating func appendTag(_ tag: String, value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            tags[tag, default: []].append(trimmed)
            lastTag = tag

            switch tag {
            case "FAU":
                authorBuilders.append(AuthorBuilder(fullAuthor: trimmed, shortAuthor: nil, orcid: nil))
            case "AU":
                // Attach to latest FAU without shortAuthor, or create standalone AU builder if FAU omitted
                if let lastIdx = authorBuilders.indices.last, authorBuilders[lastIdx].shortAuthor == nil && !authorBuilders[lastIdx].isCorporate {
                    authorBuilders[lastIdx].shortAuthor = trimmed
                } else {
                    authorBuilders.append(AuthorBuilder(fullAuthor: nil, shortAuthor: trimmed, orcid: nil))
                }
            case "CN":
                authorBuilders.append(AuthorBuilder(fullAuthor: trimmed, shortAuthor: nil, orcid: nil, isCorporate: true))
            case "AUID":
                if let lastIdx = authorBuilders.indices.last,
                   let extractedORCID = extractORCID(from: trimmed) {
                    authorBuilders[lastIdx].orcid = extractedORCID
                }
            default:
                break
            }
        }

        mutating func appendContinuation(_ continuation: String) {
            guard let tag = lastTag, !continuation.isEmpty else { return }
            if var list = tags[tag], !list.isEmpty {
                let idx = list.count - 1
                list[idx] = list[idx].isEmpty ? continuation : "\(list[idx]) \(continuation)"
                tags[tag] = list
            }
            if tag == "FAU", let lastIdx = authorBuilders.indices.last, let prev = authorBuilders[lastIdx].fullAuthor {
                authorBuilders[lastIdx].fullAuthor = "\(prev) \(continuation)"
            } else if tag == "CN", let lastIdx = authorBuilders.indices.last, let prev = authorBuilders[lastIdx].fullAuthor {
                authorBuilders[lastIdx].fullAuthor = "\(prev) \(continuation)"
            }
        }

        func first(_ candidates: String...) -> String? {
            for c in candidates {
                if let list = tags[c] {
                    for v in list where !v.isEmpty {
                        return v
                    }
                }
            }
            return nil
        }

        func all(_ candidates: String...) -> [String] {
            var res: [String] = []
            for c in candidates {
                if let list = tags[c] {
                    res.append(contentsOf: list.filter { !$0.isEmpty })
                }
            }
            return res
        }

        private func extractORCID(from auid: String) -> String? {
            let cleaned = auid
                .replacingOccurrences(of: "ORCID:", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "https://orcid.org/", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "http://orcid.org/", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let digits = cleaned.filter { $0 != "-" }
            guard digits.count == 16 else { return nil }
            if cleaned.contains("-") {
                return cleaned.uppercased()
            }
            let d = Array(digits.uppercased())
            return "\(String(d[0..<4]))-\(String(d[4..<8]))-\(String(d[8..<12]))-\(String(d[12..<16]))"
        }
    }

    private func matchNBIBTagLine(_ line: String) -> (String, String)? {
        let chars = Array(line)
        // Standard MEDLINE: columns 0..3 tag + space padded, column 4 == '-', column 5 == ' ' (e.g. `PMID- 123` or `TI  - Title`)
        if chars.count >= 5 && chars[4] == "-" {
            let rawTag = String(chars[0..<4]).trimmingCharacters(in: .whitespaces)
            guard !rawTag.isEmpty, rawTag.allSatisfy({ $0.isUppercase || $0.isNumber }) else {
                return nil
            }
            let payload: String
            if chars.count == 5 {
                payload = ""
            } else if chars[5] == " " {
                payload = chars.count > 6 ? String(chars[6...]) : ""
            } else {
                payload = String(chars[5...])
            }
            return (rawTag, payload.trimmingCharacters(in: .whitespaces))
        }
        // Tolerate 3-char tags written as `TI - ...` in loose exports
        if chars.count >= 4 && chars[3] == "-" {
            let rawTag = String(chars[0..<3]).trimmingCharacters(in: .whitespaces)
            guard !rawTag.isEmpty, rawTag.allSatisfy({ $0.isUppercase || $0.isNumber }) else {
                return nil
            }
            let payload = chars.count > 4 ? String(chars[4...]).trimmingCharacters(in: .whitespaces) : ""
            return (rawTag, payload)
        }
        return nil
    }

    private func finalizeNBIBRecord(_ record: MutableNBIBRecord, usedKeys: inout Set<String>) -> BibliographyEntry {
        let pmid = record.first("PMID")
        var rawTitle = record.first("TI", "BTI", "CTI") ?? "Untitled"
        // PubMed brackets translated titles as `[Title in English].` and appends trailing period
        if rawTitle.hasSuffix(".") && !rawTitle.hasSuffix("...") {
            rawTitle.removeLast()
        }

        let authors: [BibAuthor] = record.authorBuilders.compactMap { builder in
            if builder.isCorporate, let corp = builder.fullAuthor {
                return BibAuthor(givenName: "", familyName: corp)
            }
            if let fau = builder.fullAuthor {
                let parts = fau.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    return BibAuthor(givenName: parts[1], familyName: parts[0], orcid: builder.orcid)
                }
                return BibAuthor(givenName: "", familyName: fau, orcid: builder.orcid)
            }
            if let au = builder.shortAuthor {
                return parseMedlineAbbreviatedAuthor(au, orcid: builder.orcid)
            }
            return nil
        }

        let year = extractMedlineYear(dp: record.first("DP"), dep: record.first("DEP"))
        let venue = record.first("JT", "TA", "BTI") ?? ""
        let publisher = record.first("PB")
        let volume = record.first("VI")
        let issue = record.first("IP")
        let pages = record.first("PG").map { Self.expandMedlinePageRange($0) }

        let (doi, arxivID) = extractPersistentIDs(from: record.all("LID", "AID", "OID"))
        let abstractText = record.all("AB").joined(separator: "\n\n")
        let kind = mapPublicationTypes(record.all("PT"), hasArxiv: arxivID != nil)

        let url: String? = {
            if let doi { return "https://doi.org/\(doi)" }
            if let pmid { return "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/" }
            return nil
        }()

        var provisional = BibliographyEntry(
            citeKey: pmid.map { "pmid\($0)" } ?? "",
            kind: kind,
            title: rawTitle,
            authors: authors,
            year: year,
            venue: venue,
            publisher: publisher,
            volume: volume,
            issue: issue,
            pages: (pages?.isEmpty == true) ? nil : pages,
            doi: doi,
            arxivID: arxivID,
            pmid: pmid,
            url: url,
            abstractText: abstractText.isEmpty ? nil : abstractText
        )

        let citeKey = BibTeXCodec.generateCiteKey(for: provisional, existingKeys: usedKeys)
        usedKeys.insert(citeKey)

        provisional = BibliographyEntry(
            citeKey: citeKey,
            kind: provisional.kind,
            title: provisional.title,
            authors: provisional.authors,
            year: provisional.year,
            venue: provisional.venue,
            publisher: provisional.publisher,
            volume: provisional.volume,
            issue: provisional.issue,
            pages: provisional.pages,
            doi: provisional.doi,
            arxivID: provisional.arxivID,
            pmid: provisional.pmid,
            url: provisional.url,
            abstractText: provisional.abstractText
        )
        return provisional
    }

    private func parseMedlineAbbreviatedAuthor(_ au: String, orcid: String?) -> BibAuthor? {
        let tokens = au.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        if tokens.count == 1 {
            return BibAuthor(givenName: "", familyName: tokens[0], orcid: orcid)
        }
        // In MEDLINE `AU  - Van Der Waals JD` or `AU  - Vaswani A` -> last uppercase-initials token is given initials
        let lastToken = tokens[tokens.count - 1]
        if lastToken.count <= 4 && lastToken.allSatisfy(\.isUppercase) {
            let expandedInitials = lastToken.map { "\($0)." }.joined(separator: " ")
            let surname = tokens.dropLast().joined(separator: " ")
            return BibAuthor(givenName: expandedInitials, familyName: surname, orcid: orcid)
        }
        return BibAuthor(
            givenName: tokens.dropFirst().joined(separator: " "),
            familyName: tokens[0],
            orcid: orcid
        )
    }

    private func extractMedlineYear(dp: String?, dep: String?) -> Int? {
        if let dp {
            let chars = Array(dp)
            if chars.count >= 4 {
                for i in 0...(chars.count - 4) {
                    let sub = chars[i..<(i + 4)]
                    if sub.allSatisfy(\.isNumber), let y = Int(String(sub)) {
                        return y
                    }
                }
            }
        }
        if let dep, dep.count >= 4, let y = Int(dep.prefix(4)) {
            return y
        }
        return nil
    }

    private func extractPersistentIDs(from rawIDs: [String]) -> (doi: String?, arxiv: String?) {
        var foundDOI: String?
        var foundArxiv: String?

        for item in rawIDs {
            let lower = item.lowercased()
            if lower.hasSuffix("[doi]") {
                let candidate = String(item.dropLast(5)).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty && foundDOI == nil {
                    foundDOI = candidate
                }
            } else if lower.hasSuffix("[arxiv]") {
                var candidate = String(item.dropLast(7)).trimmingCharacters(in: .whitespaces)
                if candidate.lowercased().hasPrefix("arxiv:") {
                    candidate = String(candidate.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
                if !candidate.isEmpty && foundArxiv == nil {
                    foundArxiv = candidate
                }
            } else if foundDOI == nil && item.hasPrefix("10.") && !lower.contains("[pii]") {
                foundDOI = item.trimmingCharacters(in: .whitespaces)
            }
        }
        return (foundDOI, foundArxiv)
    }

    private func mapPublicationTypes(_ types: [String], hasArxiv: Bool) -> BibEntryKind {
        let lowerTypes = types.map { $0.lowercased() }
        if lowerTypes.contains(where: { $0.contains("preprint") }) {
            return .preprint
        }
        if lowerTypes.contains(where: { $0.contains("dissertation") || $0.contains("thesis") }) {
            return .phdthesis
        }
        if lowerTypes.contains(where: { $0.contains("technical report") }) {
            return .techreport
        }
        if lowerTypes.contains(where: { $0.contains("congress") || $0.contains("meeting") }) {
            return .inproceedings
        }
        if lowerTypes.contains(where: { $0 == "book" }) {
            return .book
        }
        if lowerTypes.contains(where: { $0.contains("book chapter") }) {
            return .incollection
        }
        if hasArxiv && lowerTypes.isEmpty {
            return .preprint
        }
        return .article
    }

    private static func splitAlphaNumericPage(_ token: String) -> (String, String) {
        let chars = Array(token)
        var splitIdx = 0
        while splitIdx < chars.count && !chars[splitIdx].isNumber {
            splitIdx += 1
        }
        let prefix = String(chars[0..<splitIdx])
        let rest = String(chars[splitIdx..<chars.count])
        guard rest.allSatisfy(\.isNumber) else {
            return (token, "")
        }
        return (prefix, rest)
    }

    private func wrapNBIBField(tag: String, value: String, maxColumnWidth: Int = 74) -> [String] {
        let paddedTag = tag.padding(toLength: 4, withPad: " ", startingAt: 0)
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return ["\(paddedTag)- "]
        }
        var lines: [String] = []
        var currentLine = "\(paddedTag)- \(words[0])"
        for word in words.dropFirst() {
            if currentLine.count + 1 + word.count > maxColumnWidth {
                lines.append(currentLine)
                currentLine = "      \(word)"
            } else {
                currentLine.append(" ")
                currentLine.append(word)
            }
        }
        lines.append(currentLine)
        return lines
    }
}
