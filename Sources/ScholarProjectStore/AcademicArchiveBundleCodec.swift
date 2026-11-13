import Foundation
import ScholarModels

// MARK: - Submission Profiles, Options & Manifests

public enum SubmissionVenueProfile: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case arxivPreprint = "arXiv"
    case neuripsCameraReady = "NeurIPS"
    case icmlCameraReady = "ICML"
    case acmTapsCameraReady = "ACM TAPS"
    case cameraReadyGeneric = "Camera-Ready"

    public var id: String { rawValue }

    public var defaultCitationStyle: CitationFormatStyle {
        switch self {
        case .arxivPreprint, .neuripsCameraReady:
            return .ieee
        case .icmlCameraReady:
            return .apa7
        case .acmTapsCameraReady:
            return .acm
        case .cameraReadyGeneric:
            return .nature
        }
    }
}

public struct SubmissionArchiveOptions: Sendable, Codable, Hashable {
    public var venueProfile: SubmissionVenueProfile
    public var rootManuscriptPath: String?
    public var flattenedOutputFileName: String
    public var bibliographyOutputFileName: String
    public var bblOutputFileName: String
    public var stripAuthorComments: Bool
    public var includeGeneratedBBL: Bool
    public var rewriteBibliographyDirective: Bool
    public var citationStyleOverride: CitationFormatStyle?
    public var allowUnverifiedCitationsOverride: Bool
    public var deterministicTimestamp: Date?

    public init(
        venueProfile: SubmissionVenueProfile = .arxivPreprint,
        rootManuscriptPath: String? = nil,
        flattenedOutputFileName: String = "ms.tex",
        bibliographyOutputFileName: String = "references.bib",
        bblOutputFileName: String = "ms.bbl",
        stripAuthorComments: Bool = true,
        includeGeneratedBBL: Bool = true,
        rewriteBibliographyDirective: Bool = true,
        citationStyleOverride: CitationFormatStyle? = nil,
        allowUnverifiedCitationsOverride: Bool = false,
        deterministicTimestamp: Date? = nil
    ) {
        self.venueProfile = venueProfile
        self.rootManuscriptPath = rootManuscriptPath
        self.flattenedOutputFileName = flattenedOutputFileName
        self.bibliographyOutputFileName = bibliographyOutputFileName
        self.bblOutputFileName = bblOutputFileName
        self.stripAuthorComments = stripAuthorComments
        self.includeGeneratedBBL = includeGeneratedBBL
        self.rewriteBibliographyDirective = rewriteBibliographyDirective
        self.citationStyleOverride = citationStyleOverride
        self.allowUnverifiedCitationsOverride = allowUnverifiedCitationsOverride
        self.deterministicTimestamp = deterministicTimestamp
    }

    public static let arxivDefault = SubmissionArchiveOptions(venueProfile: .arxivPreprint)
    public static let neuripsDefault = SubmissionArchiveOptions(venueProfile: .neuripsCameraReady)
    public static let cameraReadyDefault = SubmissionArchiveOptions(venueProfile: .cameraReadyGeneric)
}

public struct SubmissionArchiveArtifactDigest: Sendable, Codable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let role: String
    public let byteCount: Int
    public let sha256: String

    public init(relativePath: String, role: String, byteCount: Int, sha256: String) {
        self.relativePath = relativePath
        self.role = role
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct SubmissionPreflightCheck: Sendable, Codable, Hashable, Identifiable {
    public var id: String { code }
    public let code: String
    public let passed: Bool
    public let isBlocking: Bool
    public let detail: String

    public init(code: String, passed: Bool, isBlocking: Bool, detail: String) {
        self.code = code
        self.passed = passed
        self.isBlocking = isBlocking
        self.detail = detail
    }
}

public struct SubmissionArchiveManifest: Sendable, Codable, Hashable {
    public let formatVersion: Int
    public let projectTitle: String
    public let venueProfile: SubmissionVenueProfile
    public let entryManuscriptPath: String
    public let flattenedFileName: String
    public let inlinedFiles: [String]
    public let strippedCommentCount: Int
    public let flattenedWordCount: Int
    public let citedKeysInAppearanceOrder: [String]
    public let exportedBibKeys: [String]
    public let metadataDriftAdvisoryKeys: [String]
    public let overriddenUnverifiedKeys: [String]
    public let referencedGraphicsPaths: [String]
    public let artifacts: [SubmissionArchiveArtifactDigest]
    public let preflightChecks: [SubmissionPreflightCheck]
    public let bundleRootSHA256: String
    public let createdAt: Date

    public init(
        formatVersion: Int = 1,
        projectTitle: String,
        venueProfile: SubmissionVenueProfile,
        entryManuscriptPath: String,
        flattenedFileName: String,
        inlinedFiles: [String],
        strippedCommentCount: Int,
        flattenedWordCount: Int,
        citedKeysInAppearanceOrder: [String],
        exportedBibKeys: [String],
        metadataDriftAdvisoryKeys: [String],
        overriddenUnverifiedKeys: [String],
        referencedGraphicsPaths: [String],
        artifacts: [SubmissionArchiveArtifactDigest],
        preflightChecks: [SubmissionPreflightCheck],
        bundleRootSHA256: String,
        createdAt: Date
    ) {
        self.formatVersion = formatVersion
        self.projectTitle = projectTitle
        self.venueProfile = venueProfile
        self.entryManuscriptPath = entryManuscriptPath
        self.flattenedFileName = flattenedFileName
        self.inlinedFiles = inlinedFiles
        self.strippedCommentCount = strippedCommentCount
        self.flattenedWordCount = flattenedWordCount
        self.citedKeysInAppearanceOrder = citedKeysInAppearanceOrder
        self.exportedBibKeys = exportedBibKeys
        self.metadataDriftAdvisoryKeys = metadataDriftAdvisoryKeys
        self.overriddenUnverifiedKeys = overriddenUnverifiedKeys
        self.referencedGraphicsPaths = referencedGraphicsPaths
        self.artifacts = artifacts
        self.preflightChecks = preflightChecks
        self.bundleRootSHA256 = bundleRootSHA256
        self.createdAt = createdAt
    }

    public var passedAllBlockingChecks: Bool {
        preflightChecks.allSatisfy { !$0.isBlocking || $0.passed }
    }
}

public struct SubmissionArchiveBundle: Sendable, Codable, Hashable {
    public let manifest: SubmissionArchiveManifest
    public let flattenedTexContent: String
    public let filteredBibContent: String
    public let generatedBBLContent: String
    public let manifestJSONContent: String

    public init(
        manifest: SubmissionArchiveManifest,
        flattenedTexContent: String,
        filteredBibContent: String,
        generatedBBLContent: String,
        manifestJSONContent: String
    ) {
        self.manifest = manifest
        self.flattenedTexContent = flattenedTexContent
        self.filteredBibContent = filteredBibContent
        self.generatedBBLContent = generatedBBLContent
        self.manifestJSONContent = manifestJSONContent
    }
}

public struct SubmissionBundleVerificationReport: Sendable, Codable, Hashable {
    public let isValid: Bool
    public let verifiedFiles: [String]
    public let missingOrTamperedFiles: [String]
    public let expectedBundleSHA256: String
    public let recomputedBundleSHA256: String

    public init(
        isValid: Bool,
        verifiedFiles: [String],
        missingOrTamperedFiles: [String],
        expectedBundleSHA256: String,
        recomputedBundleSHA256: String
    ) {
        self.isValid = isValid
        self.verifiedFiles = verifiedFiles
        self.missingOrTamperedFiles = missingOrTamperedFiles
        self.expectedBundleSHA256 = expectedBundleSHA256
        self.recomputedBundleSHA256 = recomputedBundleSHA256
    }
}

// MARK: - AcademicArchiveBundleCodec (arXiv / NeurIPS / Camera-Ready Flattener & USTAR Codec)

public struct AcademicArchiveBundleCodec: Sendable {
    private static let recognizedCitationMacros: Set<String> = [
        "cite", "citep", "citet", "citealt", "citealp", "citeauthor", "citeyear", "citeyearpar",
        "parencite", "textcite", "autocite", "smartcite", "footcite", "supercite", "nocite", "cites"
    ]

    private static let verbatimEnvironmentNames: Set<String> = [
        "verbatim", "verbatim*", "lstlisting", "minted", "alltt", "filecontents", "filecontents*"
    ]

    public init() {}

    // MARK: - High-Level Bundle Construction & Export

    public func buildSubmissionBundle(
        from database: ScholarProjectDatabase,
        options: SubmissionArchiveOptions = .arxivDefault
    ) throws -> SubmissionArchiveBundle {
        let projectTitle = try database.projectTitle()
        let entryPath = try options.rootManuscriptPath.map(ScholarProjectDatabase.normalizeRelativePath)
            ?? database.primaryManuscriptFile()

        let allFiles = try database.listManuscriptFiles()
        var fileMap: [String: String] = [:]
        for record in allFiles {
            fileMap[ScholarProjectDatabase.normalizeRelativePath(record.path)] = record.content
        }

        guard fileMap[entryPath] != nil else {
            throw ScholarOSError.fileNotFound(entryPath)
        }

        let allBibEntries = try database.listBibliographyEntries()
        var bibByKey: [String: BibliographyEntry] = [:]
        bibByKey.reserveCapacity(allBibEntries.count)
        for entry in allBibEntries {
            bibByKey[entry.citeKey] = entry
        }

        let resolvedStyle: CitationFormatStyle
        if let explicit = options.citationStyleOverride {
            resolvedStyle = explicit
        } else if let dbStyle = try? database.preferredCitationStyle() {
            resolvedStyle = dbStyle
        } else {
            resolvedStyle = options.venueProfile.defaultCitationStyle
        }

        return try buildSubmissionBundle(
            projectTitle: projectTitle,
            entryManuscriptPath: entryPath,
            manuscriptFiles: fileMap,
            bibliographyByKey: bibByKey,
            citationStyle: resolvedStyle,
            bundleRootURL: database.projectRootURL,
            options: options
        )
    }

    public func buildSubmissionBundle(
        projectTitle: String,
        entryManuscriptPath: String,
        manuscriptFiles: [String: String],
        bibliographyByKey: [String: BibliographyEntry],
        citationStyle: CitationFormatStyle = .ieee,
        bundleRootURL: URL? = nil,
        options: SubmissionArchiveOptions = .arxivDefault
    ) throws -> SubmissionArchiveBundle {
        let normalizedEntry = ScholarProjectDatabase.normalizeRelativePath(entryManuscriptPath)

        // 1. Recursively flatten \input{...} and \include{...}, stripping comments when requested
        var visitedStack: [String] = []
        var inlinedOrder: [String] = []
        var totalStrippedComments = 0

        var flattenedTex = try flattenRecursive(
            filePath: normalizedEntry,
            manuscriptFiles: manuscriptFiles,
            bundleRootURL: bundleRootURL,
            stripComments: options.stripAuthorComments,
            inclusionStack: &visitedStack,
            inlinedFiles: &inlinedOrder,
            strippedCommentsAccumulator: &totalStrippedComments
        )

        if options.rewriteBibliographyDirective {
            let bibStem = (options.bibliographyOutputFileName as NSString).deletingPathExtension
            flattenedTex = Self.rewriteBibliographyCommand(in: flattenedTex, targetBibStem: bibStem)
        }

        // 2. Scan flattened, comment-free manuscript for cited keys (preserving first-appearance order)
        let citationScan = Self.extractCitations(from: flattenedTex)
        let citedKeys: [String]
        if citationScan.hasWildcardNocite {
            let verifiedWildcardKeys = bibliographyByKey.values
                .filter { $0.firewallClass.allowsManuscriptInsertion }
                .map(\.citeKey)
                .sorted()
            var combined = citationScan.orderedKeys
            for k in verifiedWildcardKeys where !combined.contains(k) {
                combined.append(k)
            }
            citedKeys = combined
        } else {
            citedKeys = citationScan.orderedKeys
        }

        // 3. Enforce hardware-gated 5-class Citation Verification Firewall
        var selectedEntriesInCitationOrder: [BibliographyEntry] = []
        var driftAdvisoryKeys: [String] = []
        var overriddenKeys: [String] = []

        for key in citedKeys {
            guard let entry = bibliographyByKey[key] else {
                if !options.allowUnverifiedCitationsOverride {
                    throw ScholarOSError.unverifiedCitationBlocked(
                        citeKey: key,
                        statusCode: "MISSING_BIB_ENTRY",
                        reason: "Cited key '\(key)' does not exist in bibliography_entries; archival export refused."
                    )
                }
                overriddenKeys.append(key)
                continue
            }

            if !entry.firewallClass.allowsManuscriptInsertion {
                if !options.allowUnverifiedCitationsOverride {
                    throw ScholarOSError.unverifiedCitationBlocked(
                        citeKey: entry.citeKey,
                        statusCode: entry.firewallClass.rawValue,
                        reason: entry.firewallAuditNote.isEmpty
                            ? "Entry '\(entry.citeKey)' carries \(entry.firewallClass.rawValue) status."
                            : entry.firewallAuditNote
                    )
                }
                overriddenKeys.append(entry.citeKey)
            }

            if entry.firewallClass == .metadataDriftAdvisory {
                driftAdvisoryKeys.append(entry.citeKey)
            }
            selectedEntriesInCitationOrder.append(entry)
        }

        // 4. Render filtered canonical .bib & compiled .bbl
        let sortedBibEntries = selectedEntriesInCitationOrder.sorted { $0.citeKey < $1.citeKey }
        let bibContent = Self.renderBibTeXFile(entries: sortedBibEntries)
        let bblContent = options.includeGeneratedBBL
            ? Self.renderBBLFile(entries: selectedEntriesInCitationOrder, style: citationStyle)
            : ""

        // 5. Compute SHA-256 digests, preflight checks & deterministic Merkle bundle hash
        let texData = Data(flattenedTex.utf8)
        let bibData = Data(bibContent.utf8)
        let bblData = Data(bblContent.utf8)

        var artifacts: [SubmissionArchiveArtifactDigest] = [
            SubmissionArchiveArtifactDigest(
                relativePath: options.flattenedOutputFileName,
                role: "flattened_manuscript",
                byteCount: texData.count,
                sha256: ScholarCryptoDigest.sha256Hex(texData)
            ),
            SubmissionArchiveArtifactDigest(
                relativePath: options.bibliographyOutputFileName,
                role: "filtered_bibtex",
                byteCount: bibData.count,
                sha256: ScholarCryptoDigest.sha256Hex(bibData)
            )
        ]

        if options.includeGeneratedBBL {
            artifacts.append(
                SubmissionArchiveArtifactDigest(
                    relativePath: options.bblOutputFileName,
                    role: "compiled_bbl",
                    byteCount: bblData.count,
                    sha256: ScholarCryptoDigest.sha256Hex(bblData)
                )
            )
        }

        let graphicsPaths = Self.extractIncludeGraphicsPaths(from: flattenedTex)
        let preflight = Self.evaluatePreflightChecks(
            flattenedTex: flattenedTex,
            venue: options.venueProfile,
            citedKeys: citedKeys,
            driftKeys: driftAdvisoryKeys,
            overriddenKeys: overriddenKeys,
            commentsStripped: options.stripAuthorComments
        )

        let bundleDigest = Self.computeBundleMerkleSHA256(artifacts: artifacts)
        let wordCount = ScholarWordCounter.countAcademicWords(flattenedTex, format: .latex)
        let timestamp = options.deterministicTimestamp ?? Date()

        let manifest = SubmissionArchiveManifest(
            formatVersion: 1,
            projectTitle: projectTitle,
            venueProfile: options.venueProfile,
            entryManuscriptPath: normalizedEntry,
            flattenedFileName: options.flattenedOutputFileName,
            inlinedFiles: inlinedOrder,
            strippedCommentCount: totalStrippedComments,
            flattenedWordCount: wordCount,
            citedKeysInAppearanceOrder: citedKeys,
            exportedBibKeys: sortedBibEntries.map(\.citeKey),
            metadataDriftAdvisoryKeys: driftAdvisoryKeys,
            overriddenUnverifiedKeys: overriddenKeys,
            referencedGraphicsPaths: graphicsPaths,
            artifacts: artifacts,
            preflightChecks: preflight,
            bundleRootSHA256: bundleDigest,
            createdAt: timestamp
        )

        let manifestJSON = try ScholarSQLiteJSONCodec.encodeString(manifest, prettyPrinted: true)
        return SubmissionArchiveBundle(
            manifest: manifest,
            flattenedTexContent: flattenedTex,
            filteredBibContent: bibContent,
            generatedBBLContent: bblContent,
            manifestJSONContent: manifestJSON
        )
    }

    @discardableResult
    public func exportSubmissionBundle(
        from database: ScholarProjectDatabase,
        to destinationDirectoryURL: URL,
        options: SubmissionArchiveOptions = .arxivDefault
    ) throws -> SubmissionArchiveManifest {
        let bundle = try buildSubmissionBundle(from: database, options: options)
        try writeBundle(bundle, to: destinationDirectoryURL, options: options)

        try database.recordAuditEvent(
            category: "ARCHIVE_EXPORT",
            action: "exportSubmissionBundle",
            actor: "AcademicArchiveBundleCodec",
            targetKey: destinationDirectoryURL.lastPathComponent,
            details: [
                "venue": options.venueProfile.rawValue,
                "bundle_sha256": bundle.manifest.bundleRootSHA256,
                "cited_keys": String(bundle.manifest.citedKeysInAppearanceOrder.count),
                "inlined_files": String(bundle.manifest.inlinedFiles.count)
            ]
        )

        return bundle.manifest
    }

    public func writeBundle(
        _ bundle: SubmissionArchiveBundle,
        to destinationDirectoryURL: URL,
        options: SubmissionArchiveOptions = .arxivDefault
    ) throws {
        try FileManager.default.createDirectory(
            at: destinationDirectoryURL,
            withIntermediateDirectories: true
        )

        let texURL = destinationDirectoryURL.appendingPathComponent(options.flattenedOutputFileName)
        let bibURL = destinationDirectoryURL.appendingPathComponent(options.bibliographyOutputFileName)
        let manifestURL = destinationDirectoryURL.appendingPathComponent("manifest.json")

        try Data(bundle.flattenedTexContent.utf8).write(to: texURL, options: .atomic)
        try Data(bundle.filteredBibContent.utf8).write(to: bibURL, options: .atomic)
        if options.includeGeneratedBBL {
            let bblURL = destinationDirectoryURL.appendingPathComponent(options.bblOutputFileName)
            try Data(bundle.generatedBBLContent.utf8).write(to: bblURL, options: .atomic)
        }
        try Data(bundle.manifestJSONContent.utf8).write(to: manifestURL, options: .atomic)
    }

    public func verifyExportedBundle(
        at directoryURL: URL
    ) throws -> SubmissionBundleVerificationReport {
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ScholarOSError.fileNotFound(manifestURL.path)
        }
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifestText = String(data: manifestData, encoding: .utf8) else {
            throw ScholarOSError.markupParseFailure(
                file: "manifest.json",
                line: 1,
                detail: "Manifest file is not valid UTF-8."
            )
        }
        let manifest = try ScholarSQLiteJSONCodec.decodeString(
            SubmissionArchiveManifest.self,
            from: manifestText
        )

        var verified: [String] = []
        var missingOrTampered: [String] = []
        var recomputedArtifacts: [SubmissionArchiveArtifactDigest] = []

        for expected in manifest.artifacts {
            let fileURL = directoryURL.appendingPathComponent(expected.relativePath)
            guard let bytes = try? Data(contentsOf: fileURL) else {
                missingOrTampered.append(expected.relativePath)
                continue
            }
            let actualHash = ScholarCryptoDigest.sha256Hex(bytes)
            recomputedArtifacts.append(
                SubmissionArchiveArtifactDigest(
                    relativePath: expected.relativePath,
                    role: expected.role,
                    byteCount: bytes.count,
                    sha256: actualHash
                )
            )
            if actualHash == expected.sha256 && bytes.count == expected.byteCount {
                verified.append(expected.relativePath)
            } else {
                missingOrTampered.append(expected.relativePath)
            }
        }

        let recomputedRoot = Self.computeBundleMerkleSHA256(artifacts: recomputedArtifacts)
        let valid = missingOrTampered.isEmpty && (recomputedRoot == manifest.bundleRootSHA256)

        return SubmissionBundleVerificationReport(
            isValid: valid,
            verifiedFiles: verified,
            missingOrTamperedFiles: missingOrTampered,
            expectedBundleSHA256: manifest.bundleRootSHA256,
            recomputedBundleSHA256: recomputedRoot
        )
    }

    // MARK: - Standards-Compliant POSIX.1-1988 USTAR Tarball Encoder & Decoder

    /// Encodes a submission bundle into an in-memory deterministic POSIX `ustar` `.tar` archive
    /// suitable for direct arXiv / NeurIPS upload without spawning external shell processes.
    public func encodeSubmissionTarball(
        from bundle: SubmissionArchiveBundle,
        options: SubmissionArchiveOptions = .arxivDefault
    ) -> Data {
        var entries: [(name: String, data: Data)] = [
            (options.flattenedOutputFileName, Data(bundle.flattenedTexContent.utf8)),
            (options.bibliographyOutputFileName, Data(bundle.filteredBibContent.utf8))
        ]
        if options.includeGeneratedBBL {
            entries.append((options.bblOutputFileName, Data(bundle.generatedBBLContent.utf8)))
        }
        entries.append(("manifest.json", Data(bundle.manifestJSONContent.utf8)))

        let mtime = Int64(bundle.manifest.createdAt.timeIntervalSince1970)
        var tarStream = Data()
        for entry in entries {
            tarStream.append(Self.makeUSTARHeader(fileName: entry.name, byteCount: entry.data.count, mtime: mtime))
            tarStream.append(entry.data)
            let remainder = entry.data.count % 512
            if remainder != 0 {
                tarStream.append(Data(repeating: 0, count: 512 - remainder))
            }
        }
        // Standard TAR end-of-archive marker: two consecutive 512-byte zero blocks
        tarStream.append(Data(repeating: 0, count: 1024))
        return tarStream
    }

    /// Decodes a POSIX `ustar` `.tar` archive back into a map of relative file paths to raw `Data`.
    public func decodeSubmissionTarball(_ tarData: Data) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var offset = 0

        while offset + 512 <= tarData.count {
            let header = tarData.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                break
            }

            let nameSlice = header.subdata(in: 0..<100)
            let fileName = Self.readNullTerminatedASCII(nameSlice)
            let sizeSlice = header.subdata(in: 124..<136)
            let sizeOctal = Self.readNullTerminatedASCII(sizeSlice)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let fileSize = Int(sizeOctal, radix: 8), fileSize >= 0 else {
                throw ScholarOSError.markupParseFailure(
                    file: fileName.isEmpty ? "<tar>" : fileName,
                    line: 1,
                    detail: "Malformed USTAR octal size header '\(sizeOctal)'."
                )
            }

            let payloadStart = offset + 512
            let payloadEnd = payloadStart + fileSize
            guard payloadEnd <= tarData.count else {
                throw ScholarOSError.markupParseFailure(
                    file: fileName,
                    line: 1,
                    detail: "Truncated USTAR archive payload for '\(fileName)'."
                )
            }

            if !fileName.isEmpty {
                files[fileName] = tarData.subdata(in: payloadStart..<payloadEnd)
            }

            let paddedPayloadBytes = ((fileSize + 511) / 512) * 512
            offset = payloadStart + paddedPayloadBytes
        }

        return files
    }

    private static func makeUSTARHeader(fileName: String, byteCount: Int, mtime: Int64) -> Data {
        var block = [UInt8](repeating: 0, count: 512)

        func writeASCII(_ text: String, at start: Int, maxLength: Int) {
            let utf8 = Array(text.utf8.prefix(maxLength))
            for (i, b) in utf8.enumerated() {
                block[start + i] = b
            }
        }

        func writeOctal(_ value: Int64, at start: Int, width: Int) {
            let digits = String(max(0, value), radix: 8)
            let padded = String(repeating: "0", count: max(0, width - 1 - digits.count)) + digits
            writeASCII(padded, at: start, maxLength: width - 1)
            block[start + width - 1] = 0
        }

        let cleanName = ScholarProjectDatabase.normalizeRelativePath(fileName)
        writeASCII(cleanName, at: 0, maxLength: 100)
        writeOctal(0o644, at: 100, width: 8)
        writeOctal(0, at: 108, width: 8)
        writeOctal(0, at: 116, width: 8)
        writeOctal(Int64(byteCount), at: 124, width: 12)
        writeOctal(mtime, at: 136, width: 12)

        // Fill 8-byte checksum field [148..<156] with ASCII spaces (0x20) prior to summing
        for i in 148..<156 {
            block[i] = 0x20
        }

        block[156] = UInt8(ascii: "0") // Regular file typeflag
        writeASCII("ustar", at: 257, maxLength: 5)
        block[262] = 0
        block[263] = UInt8(ascii: "0")
        block[264] = UInt8(ascii: "0")
        writeASCII("scholaros", at: 265, maxLength: 32)
        writeASCII("staff", at: 297, maxLength: 32)

        let checksum = block.reduce(0) { $0 + Int64($1) }
        let chkDigits = String(checksum, radix: 8)
        let chkPadded = String(repeating: "0", count: max(0, 6 - chkDigits.count)) + chkDigits
        writeASCII(chkPadded, at: 148, maxLength: 6)
        block[154] = 0
        block[155] = 0x20

        return Data(block)
    }

    private static func readNullTerminatedASCII(_ data: Data) -> String {
        let prefix = data.prefix { $0 != 0 }
        return String(data: prefix, encoding: .utf8) ?? ""
    }

    // MARK: - Verbatim-Safe LaTeX Comment Stripper (Preserving \%)

    /// Strips `%` author private comments while strictly preserving literal escaped `\%` signs,
    /// row-break `\\` sequences followed by `%` (`\\%` -> keeps `\\`, strips `%...`), and verbatim blocks.
    public func stripLaTeXComments(_ source: String) -> (strippedText: String, removedCommentCount: Int) {
        Self.stripLaTeXCommentsStatic(source)
    }

    private static func stripLaTeXCommentsStatic(
        _ source: String
    ) -> (strippedText: String, removedCommentCount: Int) {
        guard !source.isEmpty else { return ("", 0) }

        let normalizedNewlines = source.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false)

        var outputLines: [String] = []
        outputLines.reserveCapacity(rawLines.count)
        var activeVerbatimEnv: String?
        var removedCount = 0

        for rawLineSub in rawLines {
            let line = String(rawLineSub)

            // Check if currently inside a verbatim environment (\begin{verbatim} ... \end{verbatim})
            if let envName = activeVerbatimEnv {
                outputLines.append(line)
                if line.contains("\\end{\(envName)}") {
                    activeVerbatimEnv = nil
                }
                continue
            }

            // Detect entry into verbatim environment on this line before any unescaped %
            let processed = stripSingleLineComment(line)
            if processed.hadComment {
                removedCount += 1
                if processed.wasPureCommentLine {
                    // Omit pure comment lines completely so they do not turn into blank \par lines
                    continue
                }
            }

            if let enteredEnv = detectVerbatimBegin(in: processed.retainedLine),
               !processed.retainedLine.contains("\\end{\(enteredEnv)}")
            {
                activeVerbatimEnv = enteredEnv
            }

            outputLines.append(processed.retainedLine)
        }

        return (outputLines.joined(separator: "\n"), removedCount)
    }

    private static func stripSingleLineComment(
        _ line: String
    ) -> (retainedLine: String, hadComment: Bool, wasPureCommentLine: Bool) {
        let chars = Array(line)
        let n = chars.count
        var i = 0

        while i < n {
            // Skip inline \verb|...| delimiters so % inside \verb|100%| is preserved literally
            if chars[i] == "\\",
               i + 5 < n,
               String(chars[(i + 1)...(i + 4)]) == "verb"
            {
                var scan = i + 5
                if scan < n && chars[scan] == "*" {
                    scan += 1
                }
                if scan < n && !chars[scan].isLetter {
                    let delimiter = chars[scan]
                    scan += 1
                    while scan < n && chars[scan] != delimiter {
                        scan += 1
                    }
                    i = min(n, scan + 1)
                    continue
                }
            }

            if chars[i] == "%" {
                var slashCount = 0
                var back = i
                while back > 0 && chars[back - 1] == "\\" {
                    slashCount += 1
                    back -= 1
                }

                // Odd number of preceding backslashes => escaped literal \% (preserve!)
                // Even number of preceding backslashes => unescaped comment % (strip!)
                if slashCount % 2 == 0 {
                    let prefix = Array(chars[0..<i])
                    let pureComment = prefix.allSatisfy { $0 == " " || $0 == "\t" }
                    if pureComment {
                        return ("", true, true)
                    }

                    // Trim purely cosmetic spaces placed before inline % unless preceded by a single backslash control space `\ `
                    var trimEnd = prefix.count
                    while trimEnd > 0 && (prefix[trimEnd - 1] == " " || prefix[trimEnd - 1] == "\t") {
                        if trimEnd >= 2 && prefix[trimEnd - 2] == "\\" {
                            // Check if `\ ` control space vs `\\ ` newline + space
                            var backSlashes = 0
                            var s = trimEnd - 1
                            while s > 0 && prefix[s - 1] == "\\" {
                                backSlashes += 1
                                s -= 1
                            }
                            if backSlashes % 2 == 1 {
                                break
                            }
                        }
                        trimEnd -= 1
                    }
                    return (String(prefix[0..<trimEnd]), true, false)
                }
            }

            i += 1
        }

        return (line, false, false)
    }

    private static func detectVerbatimBegin(in line: String) -> String? {
        for env in verbatimEnvironmentNames {
            if line.contains("\\begin{\(env)}") {
                return env
            }
        }
        return nil
    }

    // MARK: - Recursive \input{...} & \include{...} Flattening

    private func flattenRecursive(
        filePath: String,
        manuscriptFiles: [String: String],
        bundleRootURL: URL?,
        stripComments: Bool,
        inclusionStack: inout [String],
        inlinedFiles: inout [String],
        strippedCommentsAccumulator: inout Int
    ) throws -> String {
        let normalizedPath = ScholarProjectDatabase.normalizeRelativePath(filePath)
        if inclusionStack.contains(normalizedPath) {
            let cycleChain = (inclusionStack + [normalizedPath]).joined(separator: " -> ")
            throw ScholarOSError.markupParseFailure(
                file: inclusionStack.last ?? normalizedPath,
                line: 1,
                detail: "Circular LaTeX \\input/\\include cycle detected: \(cycleChain)"
            )
        }

        guard let rawContent = Self.resolveManuscriptText(
            for: normalizedPath,
            in: manuscriptFiles,
            bundleRootURL: bundleRootURL
        ) else {
            throw ScholarOSError.fileNotFound(normalizedPath)
        }

        inclusionStack.append(normalizedPath)
        defer { _ = inclusionStack.popLast() }

        let workingText: String
        if stripComments {
            let stripped = Self.stripLaTeXCommentsStatic(rawContent)
            workingText = stripped.strippedText
            strippedCommentsAccumulator += stripped.removedCommentCount
        } else {
            workingText = rawContent
        }

        // Scan for \input{...} and \include{...} outside verbatim blocks
        let chars = Array(workingText)
        let n = chars.count
        var result = ""
        result.reserveCapacity(workingText.count)

        var idx = 0
        var currentLine = 1

        while idx < n {
            if chars[idx] == "\n" {
                currentLine += 1
                result.append("\n")
                idx += 1
                continue
            }

            // Skip unexpanded % comments when stripComments == false
            if !stripComments && chars[idx] == "%" && !Self.isOddBackslashEscaped(in: chars, at: idx) {
                while idx < n && chars[idx] != "\n" {
                    result.append(chars[idx])
                    idx += 1
                }
                continue
            }

            if chars[idx] == "\\",
               let directive = Self.matchIncludeDirective(in: chars, at: idx)
            {
                let childResolved = Self.resolveIncludeTargetPath(
                    rawTarget: directive.targetPath,
                    fromParentFile: normalizedPath,
                    manuscriptFiles: manuscriptFiles,
                    bundleRootURL: bundleRootURL
                )
                guard let validChildPath = childResolved else {
                    throw ScholarOSError.fileNotFound(
                        "Included manuscript '\(directive.targetPath)' referenced at \(normalizedPath):\(currentLine)"
                    )
                }

                if !inlinedFiles.contains(validChildPath) {
                    inlinedFiles.append(validChildPath)
                }

                let childFlattened = try flattenRecursive(
                    filePath: validChildPath,
                    manuscriptFiles: manuscriptFiles,
                    bundleRootURL: bundleRootURL,
                    stripComments: stripComments,
                    inclusionStack: &inclusionStack,
                    inlinedFiles: &inlinedFiles,
                    strippedCommentsAccumulator: &strippedCommentsAccumulator
                )

                if directive.command == "include" {
                    result.append("\\clearpage\n")
                    result.append(childFlattened)
                    if !childFlattened.hasSuffix("\n") {
                        result.append("\n")
                    }
                    result.append("\\clearpage")
                } else {
                    result.append(childFlattened)
                }

                idx = directive.nextIndex
                continue
            }

            result.append(chars[idx])
            idx += 1
        }

        return result
    }

    private static func resolveManuscriptText(
        for normalizedPath: String,
        in manuscriptFiles: [String: String],
        bundleRootURL: URL?
    ) -> String? {
        if let hit = manuscriptFiles[normalizedPath] {
            return hit
        }
        if let root = bundleRootURL {
            let candidates = [
                root.appendingPathComponent("manuscripts", isDirectory: true)
                    .appendingPathComponent(normalizedPath, isDirectory: false),
                root.appendingPathComponent(normalizedPath, isDirectory: false)
            ]
            for url in candidates {
                if let data = try? Data(contentsOf: url),
                   let str = String(data: data, encoding: .utf8)
                {
                    return str
                }
            }
        }
        return nil
    }

    private static func resolveIncludeTargetPath(
        rawTarget: String,
        fromParentFile parentFile: String,
        manuscriptFiles: [String: String],
        bundleRootURL: URL?
    ) -> String? {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let hasTexExt = (trimmed as NSString).pathExtension.lowercased() == "tex"
        let baseCandidates = hasTexExt ? [trimmed] : [trimmed, "\(trimmed).tex"]

        let parentDir = (parentFile as NSString).deletingLastPathComponent
        var fullCandidates: [String] = []
        for c in baseCandidates {
            fullCandidates.append(ScholarProjectDatabase.normalizeRelativePath(c))
            if !parentDir.isEmpty && parentDir != "." {
                fullCandidates.append(
                    ScholarProjectDatabase.normalizeRelativePath("\(parentDir)/\(c)")
                )
            }
        }

        for candidate in fullCandidates {
            if resolveManuscriptText(for: candidate, in: manuscriptFiles, bundleRootURL: bundleRootURL) != nil {
                return candidate
            }
        }
        return nil
    }

    private static func matchIncludeDirective(
        in chars: [Character],
        at backslashIndex: Int
    ) -> (command: String, targetPath: String, nextIndex: Int)? {
        var idx = backslashIndex + 1
        let startCmd = idx
        while idx < chars.count && chars[idx].isLetter {
            idx += 1
        }
        let command = String(chars[startCmd..<idx])
        guard command == "input" || command == "include" else {
            return nil
        }

        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t") {
            idx += 1
        }
        guard idx < chars.count && chars[idx] == "{" else {
            return nil
        }

        idx += 1
        let argStart = idx
        var depth = 1
        while idx < chars.count && depth > 0 {
            if chars[idx] == "\n" || chars[idx] == "\r" {
                return nil
            }
            if chars[idx] == "{" {
                depth += 1
            } else if chars[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    let target = String(chars[argStart..<idx])
                    return (command: command, targetPath: target, nextIndex: idx + 1)
                }
            }
            idx += 1
        }
        return nil
    }

    private static func isOddBackslashEscaped(in chars: [Character], at index: Int) -> Bool {
        var slashes = 0
        var scan = index
        while scan > 0 && chars[scan - 1] == "\\" {
            slashes += 1
            scan -= 1
        }
        return slashes % 2 == 1
    }

    private static func rewriteBibliographyCommand(in source: String, targetBibStem: String) -> String {
        let chars = Array(source)
        var out = ""
        out.reserveCapacity(source.count)
        var i = 0

        while i < chars.count {
            if chars[i] == "\\",
               i + 13 < chars.count,
               String(chars[(i + 1)...(i + 12)]) == "bibliography"
            {
                let afterCmd = i + 13
                if afterCmd < chars.count && !chars[afterCmd].isLetter {
                    var scan = afterCmd
                    while scan < chars.count && (chars[scan] == " " || chars[scan] == "\t") {
                        scan += 1
                    }
                    if scan < chars.count && chars[scan] == "{" {
                        var close = scan + 1
                        while close < chars.count && chars[close] != "}" && chars[close] != "\n" {
                            close += 1
                        }
                        if close < chars.count && chars[close] == "}" {
                            out.append("\\bibliography{\(targetBibStem)}")
                            i = close + 1
                            continue
                        }
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    // MARK: - Citation & Graphics AST Token Extraction

    public static func extractCitedKeys(from latexSource: String) -> [String] {
        let commentFree = stripLaTeXCommentsStatic(latexSource).strippedText
        return extractCitations(from: commentFree).orderedKeys
    }

    private static func extractCitations(
        from source: String
    ) -> (orderedKeys: [String], hasWildcardNocite: Bool) {
        let chars = Array(source)
        let n = chars.count
        var ordered: [String] = []
        var seen = Set<String>()
        var wildcard = false
        var i = 0

        while i < n {
            if chars[i] == "%" && !isOddBackslashEscaped(in: chars, at: i) {
                while i < n && chars[i] != "\n" {
                    i += 1
                }
                continue
            }

            if chars[i] == "\\" {
                i += 1
                let cmdStart = i
                while i < n && chars[i].isLetter {
                    i += 1
                }
                let cmd = String(chars[cmdStart..<i])
                if i < n && chars[i] == "*" {
                    i += 1
                }

                if recognizedCitationMacros.contains(cmd) {
                    var consumedGroup = false
                    while i < n {
                        while i < n && (chars[i] == " " || chars[i] == "\t") {
                            i += 1
                        }
                        if i < n && chars[i] == "[" {
                            // Skip optional prenote / postnote bracket argument
                            var depth = 0
                            while i < n {
                                if chars[i] == "[" { depth += 1 }
                                else if chars[i] == "]" {
                                    depth -= 1
                                    if depth == 0 { i += 1; break }
                                }
                                i += 1
                            }
                            continue
                        }
                        if i < n && chars[i] == "{" {
                            i += 1
                            let groupStart = i
                            var depth = 1
                            while i < n && depth > 0 {
                                if chars[i] == "{" { depth += 1 }
                                else if chars[i] == "}" { depth -= 1 }
                                i += 1
                            }
                            let groupBody = String(chars[groupStart..<(i - 1)])
                            consumedGroup = true
                            for rawKey in groupBody.split(separator: ",") {
                                let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                if key == "*" && cmd == "nocite" {
                                    wildcard = true
                                } else if !key.isEmpty && !seen.contains(key) {
                                    seen.insert(key)
                                    ordered.append(key)
                                }
                            }
                            // Only multi-cite commands like \cites consume consecutive {k1}{k2}
                            if cmd != "cites" {
                                break
                            }
                        } else {
                            break
                        }
                    }
                    if consumedGroup {
                        continue
                    }
                }
                continue
            }

            i += 1
        }

        return (orderedKeys: ordered, hasWildcardNocite: wildcard)
    }

    private static func extractIncludeGraphicsPaths(from source: String) -> [String] {
        let chars = Array(source)
        let n = chars.count
        var paths: [String] = []
        var i = 0

        while i < n {
            if chars[i] == "\\",
               i + 16 < n,
               String(chars[(i + 1)...(i + 15)]) == "includegraphics"
            {
                i += 16
                if i < n && chars[i] == "*" { i += 1 }
                while i < n && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                if i < n && chars[i] == "[" {
                    var depth = 0
                    while i < n {
                        if chars[i] == "[" { depth += 1 }
                        else if chars[i] == "]" {
                            depth -= 1
                            if depth == 0 { i += 1; break }
                        }
                        i += 1
                    }
                }
                while i < n && (chars[i] == " " || chars[i] == "\t") { i += 1 }
                if i < n && chars[i] == "{" {
                    i += 1
                    let start = i
                    while i < n && chars[i] != "}" && chars[i] != "\n" {
                        i += 1
                    }
                    if i < n && chars[i] == "}" {
                        let p = String(chars[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !p.isEmpty && !paths.contains(p) {
                            paths.append(p)
                        }
                    }
                }
            }
            i += 1
        }
        return paths
    }

    // MARK: - Canonical BibTeX & Multi-Style .bbl Emitters

    public static func renderBibTeXFile(entries: [BibliographyEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var blocks: [String] = []
        blocks.reserveCapacity(entries.count)

        for entry in entries {
            let bibType: String
            switch entry.kind {
            case .preprint:
                bibType = "misc"
            default:
                bibType = entry.kind.rawValue
            }

            var fields: [(String, String)] = []
            let authorLine = entry.authors.map { author in
                author.givenName.isEmpty
                    ? author.familyName
                    : "\(author.familyName), \(author.givenName)"
            }.joined(separator: " and ")

            if !authorLine.isEmpty {
                fields.append(("author", authorLine))
            }
            fields.append(("title", "{\(entry.title)}"))

            if !entry.venue.isEmpty {
                switch entry.kind {
                case .inproceedings, .incollection:
                    fields.append(("booktitle", entry.venue))
                case .techreport, .phdthesis:
                    fields.append(("institution", entry.venue))
                case .preprint, .misc:
                    fields.append(("howpublished", entry.venue))
                case .article, .book:
                    fields.append(("journal", entry.venue))
                }
            }

            if let year = entry.year {
                fields.append(("year", String(year)))
            }
            if let publisher = entry.publisher, !publisher.isEmpty {
                fields.append(("publisher", publisher))
            }
            if let volume = entry.volume, !volume.isEmpty {
                fields.append(("volume", volume))
            }
            if let issue = entry.issue, !issue.isEmpty {
                fields.append(("number", issue))
            }
            if let pages = entry.pages, !pages.isEmpty {
                fields.append(("pages", pages))
            }
            if let doi = entry.doi, !doi.isEmpty {
                fields.append(("doi", doi))
            }
            if let arxiv = entry.arxivID, !arxiv.isEmpty {
                fields.append(("eprint", arxiv))
                fields.append(("archivePrefix", "arXiv"))
            }
            if let pmid = entry.pmid, !pmid.isEmpty {
                fields.append(("pmid", pmid))
            }
            if let url = entry.url, !url.isEmpty {
                fields.append(("url", url))
            }

            let formattedFields = fields.map { key, val in
                "  \(key) = {\(val)}"
            }.joined(separator: ",\n")

            blocks.append("@\(bibType){\(entry.citeKey),\n\(formattedFields)\n}")
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    public static func renderBBLFile(
        entries: [BibliographyEntry],
        style: CitationFormatStyle
    ) -> String {
        let widestLabel = String(repeating: "9", count: max(1, String(entries.count).count))
        var lines: [String] = ["\\begin{thebibliography}{\(widestLabel)}"]

        for entry in entries {
            let escapedTitle = escapeLaTeXProse(entry.title)
            let escapedVenue = escapeLaTeXProse(entry.venue)
            let yearStr = entry.year.map(String.init) ?? "n.d."

            let formattedBody: String
            switch style {
            case .ieee:
                let authors = entry.authors.map(\.ieeeForm).joined(separator: ", ")
                var parts = ["\(authors), ``\(escapedTitle),''"]
                if !escapedVenue.isEmpty {
                    parts.append("\\emph{\(escapedVenue)},")
                }
                if let vol = entry.volume { parts.append("vol.~\(vol),") }
                if let pages = entry.pages { parts.append("pp.~\(pages),") }
                parts.append("\(yearStr).")
                if let doi = entry.doi { parts.append("doi: \\texttt{\(escapeLaTeXProse(doi))}.") }
                formattedBody = parts.joined(separator: " ")

            case .apa7:
                let authors = entry.authors.map(\.apaShortForm).joined(separator: ", ")
                var parts = ["\(authors) (\(yearStr)). \(escapedTitle)."]
                if !escapedVenue.isEmpty {
                    parts.append("\\emph{\(escapedVenue)}.")
                }
                if let doi = entry.doi {
                    parts.append("https://doi.org/\(escapeLaTeXProse(doi))")
                }
                formattedBody = parts.joined(separator: " ")

            case .acm:
                let authors = entry.authors.map(\.description).joined(separator: ", ")
                var parts = ["\(authors). \(yearStr). \(escapedTitle)."]
                if !escapedVenue.isEmpty {
                    parts.append("In \\emph{\(escapedVenue)}.")
                }
                if let pages = entry.pages { parts.append("\(pages).") }
                formattedBody = parts.joined(separator: " ")

            case .nature, .vancouver:
                let authors = entry.authors.map(\.apaShortForm).joined(separator: ", ")
                var parts = ["\(authors) \(escapedTitle)."]
                if !escapedVenue.isEmpty {
                    parts.append("\\emph{\(escapedVenue)}")
                }
                if let vol = entry.volume { parts.append("\\textbf{\(vol)},") }
                if let pages = entry.pages { parts.append("\(pages)") }
                parts.append("(\(yearStr)).")
                formattedBody = parts.joined(separator: " ")
            }

            lines.append("")
            lines.append("\\bibitem{\(entry.citeKey)}")
            lines.append(formattedBody)
        }

        lines.append("")
        lines.append("\\end{thebibliography}")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func escapeLaTeXProse(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count + 8)
        for ch in raw {
            switch ch {
            case "&": out.append("\\&")
            case "%": out.append("\\%")
            case "_": out.append("\\_")
            case "#": out.append("\\#")
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Preflight Validation & Merkle Bundle Digest

    private static func evaluatePreflightChecks(
        flattenedTex: String,
        venue: SubmissionVenueProfile,
        citedKeys: [String],
        driftKeys: [String],
        overriddenKeys: [String],
        commentsStripped: Bool
    ) -> [SubmissionPreflightCheck] {
        var checks: [SubmissionPreflightCheck] = []

        let hasRemainingInputs = flattenedTex.contains("\\input{") || flattenedTex.contains("\\include{")
        checks.append(
            SubmissionPreflightCheck(
                code: "FLAT_SINGLE_FILE",
                passed: !hasRemainingInputs,
                isBlocking: true,
                detail: hasRemainingInputs
                    ? "Residual \\input or \\include directive detected in flattened output."
                    : "All \\input and \\include manuscript fragments were cleanly flattened into a single TeX unit."
            )
        )

        if commentsStripped {
            let residualComments = stripLaTeXCommentsStatic(flattenedTex).removedCommentCount
            checks.append(
                SubmissionPreflightCheck(
                    code: "NO_PRIVATE_COMMENTS",
                    passed: residualComments == 0,
                    isBlocking: true,
                    detail: residualComments == 0
                        ? "Zero unescaped private % comments remain; literal \\% tokens preserved."
                        : "Found \(residualComments) unstripped % comment line(s)."
                )
            )
        }

        checks.append(
            SubmissionPreflightCheck(
                code: "CITATION_FIREWALL_GATE",
                passed: overriddenKeys.isEmpty,
                isBlocking: false,
                detail: overriddenKeys.isEmpty
                    ? "All \(citedKeys.count) cited bibliographic key(s) passed Citation Verification Firewall."
                    : "WARNING: Explicit override bypassed Citation Firewall for keys: \(overriddenKeys.joined(separator: ", "))."
            )
        )

        checks.append(
            SubmissionPreflightCheck(
                code: "METADATA_DRIFT_ADVISORY",
                passed: driftKeys.isEmpty,
                isBlocking: false,
                detail: driftKeys.isEmpty
                    ? "No preprint-vs-proceedings metadata drift advisories among cited keys."
                    : "Advisory: Verify camera-ready proceedings metadata for \(driftKeys.joined(separator: ", "))."
            )
        )

        let hasBeginEndDoc = flattenedTex.contains("\\begin{document}") && flattenedTex.contains("\\end{document}")
        checks.append(
            SubmissionPreflightCheck(
                code: "DOCUMENT_BOUNDARIES_\(venue.rawValue.uppercased().replacingOccurrences(of: " ", with: "_"))",
                passed: hasBeginEndDoc,
                isBlocking: false,
                detail: hasBeginEndDoc
                    ? "Balanced \\begin{document} ... \\end{document} envelope verified for \(venue.rawValue)."
                    : "Flattened output is a LaTeX fragment without top-level \\begin{document}."
            )
        )

        return checks
    }

    private static func computeBundleMerkleSHA256(
        artifacts: [SubmissionArchiveArtifactDigest]
    ) -> String {
        let canonicalLines = artifacts
            .sorted { $0.relativePath < $1.relativePath }
            .map { "\($0.relativePath):\($0.byteCount):\($0.sha256)" }
            .joined(separator: "\n")
        return ScholarCryptoDigest.sha256Hex(canonicalLines)
    }
}
