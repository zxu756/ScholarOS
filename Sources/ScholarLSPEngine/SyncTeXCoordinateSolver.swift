import Foundation
import zlib
import ScholarModels
import ScholarMarkupAST

// MARK: - SyncTeX v1 Models & Bidirectional Search Results

public enum SyncTeXRecordKind: String, Sendable, Codable, Hashable, CaseIterable {
    case vbox = "vbox"
    case hbox = "hbox"
    case voidVBox = "void_vbox"
    case voidHBox = "void_hbox"
    case currentLeaf = "current"
    case glue = "glue"
    case kern = "kern"
    case math = "math"
    case formRef = "form_ref"

    public var isLeafOrLineLevel: Bool {
        switch self {
        case .vbox:
            return false
        case .hbox, .voidVBox, .voidHBox, .currentLeaf, .glue, .kern, .math, .formRef:
            return true
        }
    }
}

public struct SyncTeXGeometricRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String {
        "\(kind.rawValue):\(inputTag):\(line):\(column)@p\(pdfPageIndex):\(Int(xPt))x\(Int(yPt))"
    }
    public let kind: SyncTeXRecordKind
    public let inputTag: Int
    public let sourceFile: String
    public let line: Int
    public let column: Int
    public let pdfPageIndex: Int
    public let xPt: Double
    public let yPt: Double
    public let widthPt: Double
    public let heightPt: Double

    public init(
        kind: SyncTeXRecordKind,
        inputTag: Int,
        sourceFile: String,
        line: Int,
        column: Int = 1,
        pdfPageIndex: Int,
        xPt: Double,
        yPt: Double,
        widthPt: Double,
        heightPt: Double
    ) {
        self.kind = kind
        self.inputTag = inputTag
        self.sourceFile = sourceFile
        self.line = line
        self.column = column
        self.pdfPageIndex = pdfPageIndex
        self.xPt = xPt
        self.yPt = yPt
        self.widthPt = widthPt
        self.heightPt = heightPt
    }

    public var areaPtSquared: Double {
        max(1.0, widthPt) * max(1.0, heightPt)
    }

    public func toAnchor() -> SyncTeXAnchor {
        SyncTeXAnchor(
            sourceFile: sourceFile,
            line: line,
            column: column,
            pdfPageIndex: pdfPageIndex,
            xPt: xPt,
            yPt: yPt,
            widthPt: max(4.0, widthPt),
            heightPt: max(8.0, heightPt)
        )
    }

    public func containsPoint(x: Double, y: Double, tolerancePt: Double = 1.5) -> Bool {
        let minX = xPt - tolerancePt
        let maxX = xPt + max(4.0, widthPt) + tolerancePt
        let minY = yPt - tolerancePt
        let maxY = yPt + max(8.0, heightPt) + tolerancePt
        return x >= minX && x <= maxX && y >= minY && y <= maxY
    }

    public func euclideanDistance(toX x: Double, y: Double) -> Double {
        let minX = xPt
        let maxX = xPt + max(2.0, widthPt)
        let minY = yPt
        let maxY = yPt + max(6.0, heightPt)

        let dx: Double
        if x < minX { dx = minX - x }
        else if x > maxX { dx = x - maxX }
        else { dx = 0.0 }

        let dy: Double
        if y < minY { dy = minY - y }
        else if y > maxY { dy = y - maxY }
        else { dy = 0.0 }

        return hypot(dx, dy)
    }
}

public struct SyncTeXPreamble: Sendable, Codable, Hashable {
    public let version: Int
    public let outputFormat: String
    public let magnification: Int
    public let unit: Int
    public let xOffsetSP: Int
    public let yOffsetSP: Int
    public let inputsByTag: [Int: String]

    public init(
        version: Int = 1,
        outputFormat: String = "pdf",
        magnification: Int = 1000,
        unit: Int = 1,
        xOffsetSP: Int = 0,
        yOffsetSP: Int = 0,
        inputsByTag: [Int: String] = [:]
    ) {
        self.version = version
        self.outputFormat = outputFormat
        self.magnification = magnification
        self.unit = unit
        self.xOffsetSP = xOffsetSP
        self.yOffsetSP = yOffsetSP
        self.inputsByTag = inputsByTag
    }

    /// Conversion factor from SyncTeX scaled points (`65536 sp = 1 bp/pt` at `Unit:1, Magnification:1000`) to PDF points.
    public var scaledPointsToPDFPointsFactor: Double {
        let u = Double(max(1, unit))
        let mag = Double(max(1, magnification)) / 1000.0
        return (u * mag) / 65536.0
    }
}

public struct SyncTeXInverseMatch: Sendable, Codable, Hashable {
    public let sourceFile: String
    public let line: Int
    public let column: Int
    public let anchor: SyncTeXAnchor
    public let euclideanDistancePt: Double
    public let isExactEnclosure: Bool

    public init(
        sourceFile: String,
        line: Int,
        column: Int,
        anchor: SyncTeXAnchor,
        euclideanDistancePt: Double,
        isExactEnclosure: Bool
    ) {
        self.sourceFile = sourceFile
        self.line = line
        self.column = column
        self.anchor = anchor
        self.euclideanDistancePt = euclideanDistancePt
        self.isExactEnclosure = isExactEnclosure
    }

    public var tuple: (sourceFile: String, line: Int, column: Int, anchor: SyncTeXAnchor) {
        (sourceFile, line, column, anchor)
    }
}

// MARK: - Pure-Swift Zlib / Gzip Codec (`<zlib.h>`)

public enum SyncTeXZlibCodec: Sendable {
    public static func isCompressedGzipOrZlib(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let b0 = data[data.startIndex]
        let b1 = data[data.index(after: data.startIndex)]
        // Gzip magic `0x1F 0x8B`
        if b0 == 0x1F && b1 == 0x8B {
            return true
        }
        // Zlib header check (`CMF * 256 + FLG` divisible by 31, CM == 8)
        if (b0 & 0x0F) == 8 && ((Int(b0) * 256 + Int(b1)) % 31 == 0) {
            return true
        }
        return false
    }

    public static func decompressIfNeeded(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard isCompressedGzipOrZlib(data) else {
            return data
        }
        return try inflateGzipOrZlib(data)
    }

    public static func inflateGzipOrZlib(_ compressed: Data) throws -> Data {
        guard !compressed.isEmpty else { return Data() }

        var stream = z_stream()
        // `MAX_WBITS + 32` (47) instructs zlib to auto-detect both RFC 1952 gzip and RFC 1950 zlib headers!
        let initStatus = inflateInit2_(
            &stream,
            MAX_WBITS + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw ScholarOSError.syncTeXMappingNotFound("zlib inflateInit2 failed with code \(initStatus).")
        }
        defer {
            inflateEnd(&stream)
        }

        var output = Data()
        output.reserveCapacity(compressed.count * 4)
        var chunk = [UInt8](repeating: 0, count: 65_536)

        try compressed.withUnsafeBytes { rawInput in
            guard let baseAddress = rawInput.bindMemory(to: Bytef.self).baseAddress else {
                return
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
            stream.avail_in = uInt(rawInput.count)

            while true {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { outBuf -> Int in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(outBuf.count)

                    let code = inflate(&stream, Z_NO_FLUSH)
                    if code != Z_OK && code != Z_STREAM_END && code != Z_BUF_ERROR {
                        throw ScholarOSError.syncTeXMappingNotFound("Corrupt .synctex.gz stream (zlib status \(code)).")
                    }
                    let bytesWritten = outBuf.count - Int(stream.avail_out)
                    if code == Z_STREAM_END {
                        return -1 - bytesWritten
                    }
                    return bytesWritten
                }

                if produced < 0 {
                    let finalBytes = -(produced + 1)
                    if finalBytes > 0 {
                        output.append(chunk, count: finalBytes)
                    }
                    break
                } else if produced > 0 {
                    output.append(chunk, count: produced)
                } else if stream.avail_in == 0 {
                    break
                }
            }
        }

        return output
    }

    public static func compressGzip(_ rawData: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        var stream = z_stream()
        // `MAX_WBITS + 16` (31) produces standard RFC 1952 `.gz` headers & CRC32 trailer!
        let initStatus = deflateInit2_(
            &stream,
            level,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw ScholarOSError.syncTeXMappingNotFound("zlib deflateInit2 failed with code \(initStatus).")
        }
        defer {
            deflateEnd(&stream)
        }

        var output = Data()
        output.reserveCapacity(max(128, rawData.count / 2))
        var chunk = [UInt8](repeating: 0, count: 32_768)

        try rawData.withUnsafeBytes { rawInput in
            if let base = rawInput.bindMemory(to: Bytef.self).baseAddress {
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base)
            }
            stream.avail_in = uInt(rawInput.count)

            var finished = false
            while !finished {
                try chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(outBuf.count)
                    let status = deflate(&stream, Z_FINISH)
                    if status == Z_STREAM_ERROR {
                        throw ScholarOSError.syncTeXMappingNotFound("zlib deflate failed with Z_STREAM_ERROR.")
                    }
                    let have = outBuf.count - Int(stream.avail_out)
                    if have > 0 {
                        output.append(outBuf.baseAddress!, count: have)
                    }
                    if status == Z_STREAM_END {
                        finished = true
                    }
                }
            }
        }

        return output
    }
}

// MARK: - SyncTeX v1 State Machine Parser & Bidirectional Geometric Solver

public struct SyncTeXCoordinateSolver: Sendable, Codable, Hashable {
    public let preamble: SyncTeXPreamble
    public let pageCount: Int
    public let records: [SyncTeXGeometricRecord]
    public let coalescedLineAnchors: [SyncTeXAnchor]

    private let recordsByPage: [Int: [SyncTeXGeometricRecord]]
    private let anchorsByNormalizedFile: [String: [SyncTeXAnchor]]

    public init(
        preamble: SyncTeXPreamble = SyncTeXPreamble(),
        pageCount: Int = 0,
        records: [SyncTeXGeometricRecord] = []
    ) {
        self.preamble = preamble
        self.records = records
        self.pageCount = max(pageCount, (records.map(\.pdfPageIndex).max().map { $0 + 1 }) ?? 0)

        var byPage: [Int: [SyncTeXGeometricRecord]] = [:]
        for rec in records {
            byPage[rec.pdfPageIndex, default: []].append(rec)
        }
        self.recordsByPage = byPage

        let builtAnchors = Self.buildCoalescedLineAnchors(from: records)
        self.coalescedLineAnchors = builtAnchors

        var byFile: [String: [SyncTeXAnchor]] = [:]
        for anchor in builtAnchors {
            let norm = Self.normalizeSyncPath(anchor.sourceFile)
            byFile[norm, default: []].append(anchor)
        }
        for key in byFile.keys {
            byFile[key]?.sort { lhs, rhs in
                if lhs.line != rhs.line { return lhs.line < rhs.line }
                return lhs.pdfPageIndex < rhs.pdfPageIndex
            }
        }
        self.anchorsByNormalizedFile = byFile
    }

    /// Parses either uncompressed `.synctex` or gzip/zlib-compressed `.synctex.gz` binary payload.
    public init(data: Data) throws {
        let decompressed = try SyncTeXZlibCodec.decompressIfNeeded(data)
        let text = String(decoding: decompressed, as: UTF8.self)
        self = try Self.parseSyncTeXText(text)
    }

    /// Parses raw `.synctex` text directly.
    public init(syncTeXString: String) throws {
        self = try Self.parseSyncTeXText(syncTeXString)
    }

    /// Loads a `.synctex` or `.synctex.gz` file from disk.
    public static func load(fromFilePath path: String) throws -> SyncTeXCoordinateSolver {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScholarOSError.fileNotFound(path)
        }
        let data = try Data(contentsOf: url)
        return try SyncTeXCoordinateSolver(data: data)
    }

    // MARK: - Forward Search (`(sourceFile, line, column)` -> PDF `SyncTeXAnchor`)

    public func forwardSearch(
        sourceFile: String,
        line: Int,
        column: Int = 1
    ) -> SyncTeXAnchor? {
        guard !coalescedLineAnchors.isEmpty else { return nil }
        let targetLine = max(1, line)
        let targetCol = max(1, column)

        guard let matchedNormKey = resolveMatchingFileKey(for: sourceFile),
              let fileAnchors = anchorsByNormalizedFile[matchedNormKey],
              !fileAnchors.isEmpty else {
            return nil
        }

        // 1. Exact line match
        let exactMatches = fileAnchors.filter { $0.line == targetLine }
        if let primaryExact = exactMatches.first {
            // If column > 1 and multiple leaf records exist on this exact line, refine horizontal highlight!
            if targetCol > 1 {
                let lineRecords = (recordsByPage[primaryExact.pdfPageIndex] ?? []).filter {
                    Self.normalizeSyncPath($0.sourceFile) == matchedNormKey
                        && $0.line == targetLine
                        && $0.kind.isLeafOrLineLevel
                }
                if let colMatch = lineRecords.min(by: { abs($0.column - targetCol) < abs($1.column - targetCol) }),
                   colMatch.column > 1 {
                    return SyncTeXAnchor(
                        sourceFile: sourceFile,
                        line: targetLine,
                        column: colMatch.column,
                        pdfPageIndex: colMatch.pdfPageIndex,
                        xPt: colMatch.xPt,
                        yPt: primaryExact.yPt,
                        widthPt: max(24.0, colMatch.widthPt),
                        heightPt: primaryExact.heightPt
                    )
                }
            }
            return SyncTeXAnchor(
                sourceFile: sourceFile,
                line: primaryExact.line,
                column: targetCol,
                pdfPageIndex: primaryExact.pdfPageIndex,
                xPt: primaryExact.xPt,
                yPt: primaryExact.yPt,
                widthPt: primaryExact.widthPt,
                heightPt: primaryExact.heightPt
            )
        }

        // 2. Nearest interpolated line within the same file!
        var preceding: SyncTeXAnchor? = nil
        var succeeding: SyncTeXAnchor? = nil
        for anchor in fileAnchors {
            if anchor.line < targetLine {
                preceding = anchor
            } else if anchor.line > targetLine {
                succeeding = anchor
                break
            }
        }

        if let prev = preceding, let next = succeeding {
            if prev.pdfPageIndex == next.pdfPageIndex && next.line > prev.line {
                let ratio = Double(targetLine - prev.line) / Double(next.line - prev.line)
                let interpY = prev.yPt + ratio * (next.yPt - prev.yPt)
                let interpW = max(prev.widthPt, next.widthPt)
                let interpH = (prev.heightPt + next.heightPt) * 0.5
                return SyncTeXAnchor(
                    sourceFile: sourceFile,
                    line: targetLine,
                    column: targetCol,
                    pdfPageIndex: prev.pdfPageIndex,
                    xPt: min(prev.xPt, next.xPt),
                    yPt: interpY,
                    widthPt: interpW,
                    heightPt: interpH
                )
            }
            // Different pages: pick whichever recorded line is closer in line number
            let pick = (targetLine - prev.line <= next.line - targetLine) ? prev : next
            return SyncTeXAnchor(
                sourceFile: sourceFile,
                line: pick.line,
                column: targetCol,
                pdfPageIndex: pick.pdfPageIndex,
                xPt: pick.xPt,
                yPt: pick.yPt,
                widthPt: pick.widthPt,
                heightPt: pick.heightPt
            )
        }

        if let onlyPrev = preceding {
            return SyncTeXAnchor(
                sourceFile: sourceFile,
                line: onlyPrev.line,
                column: targetCol,
                pdfPageIndex: onlyPrev.pdfPageIndex,
                xPt: onlyPrev.xPt,
                yPt: onlyPrev.yPt,
                widthPt: onlyPrev.widthPt,
                heightPt: onlyPrev.heightPt
            )
        }

        if let onlyNext = succeeding {
            return SyncTeXAnchor(
                sourceFile: sourceFile,
                line: onlyNext.line,
                column: targetCol,
                pdfPageIndex: onlyNext.pdfPageIndex,
                xPt: onlyNext.xPt,
                yPt: onlyNext.yPt,
                widthPt: onlyNext.widthPt,
                heightPt: onlyNext.heightPt
            )
        }

        return nil
    }

    public func resolveForwardSearch(
        sourceFile: String,
        line: Int,
        column: Int = 1
    ) throws -> SyncTeXAnchor {
        guard let anchor = forwardSearch(sourceFile: sourceFile, line: line, column: column) else {
            throw ScholarOSError.syncTeXMappingNotFound("No SyncTeX anchor mapped for \(sourceFile):\(line):\(column).")
        }
        return anchor
    }

    // MARK: - Inverse Search (`(pdfPageIndex, xPt, yPt)` -> `(sourceFile, line, column, SyncTeXAnchor)`)

    public func inverseSearch(
        pdfPageIndex: Int,
        xPt: Double,
        yPt: Double
    ) -> SyncTeXInverseMatch? {
        guard let pageRecords = recordsByPage[pdfPageIndex], !pageRecords.isEmpty else {
            return nil
        }

        // Filter to valid source-mapped records (`line >= 1` and non-empty `sourceFile`)
        let validRecords = pageRecords.filter { $0.line >= 1 && !$0.sourceFile.isEmpty }
        guard !validRecords.isEmpty else { return nil }

        // 1. Prefer leaf/line-level records enclosing `(xPt, yPt)`, choosing smallest bounding area!
        let enclosingLeaves = validRecords.filter { $0.kind.isLeafOrLineLevel && $0.containsPoint(x: xPt, y: yPt) }
        if let bestLeaf = enclosingLeaves.min(by: { lhs, rhs in
            if abs(lhs.areaPtSquared - rhs.areaPtSquared) > 1e-3 {
                return lhs.areaPtSquared < rhs.areaPtSquared
            }
            return lhs.line > rhs.line
        }) {
            let anchor = coalescedAnchorOrFallback(for: bestLeaf)
            return SyncTeXInverseMatch(
                sourceFile: bestLeaf.sourceFile,
                line: bestLeaf.line,
                column: bestLeaf.column,
                anchor: anchor,
                euclideanDistancePt: 0.0,
                isExactEnclosure: true
            )
        }

        // Check enclosing container vboxes if no leaf enclosed directly
        let enclosingBoxes = validRecords.filter { $0.containsPoint(x: xPt, y: yPt) }
        if let smallestBox = enclosingBoxes.min(by: { $0.areaPtSquared < $1.areaPtSquared }) {
            // Within that container, check if a leaf record is closer vertically than the generic container header
            let leafCandidates = validRecords.filter(\.kind.isLeafOrLineLevel)
            if let closestLeaf = leafCandidates.min(by: { $0.euclideanDistance(toX: xPt, y: yPt) < $1.euclideanDistance(toX: xPt, y: yPt) }),
               closestLeaf.euclideanDistance(toX: xPt, y: yPt) <= 24.0 {
                let dist = closestLeaf.euclideanDistance(toX: xPt, y: yPt)
                return SyncTeXInverseMatch(
                    sourceFile: closestLeaf.sourceFile,
                    line: closestLeaf.line,
                    column: closestLeaf.column,
                    anchor: coalescedAnchorOrFallback(for: closestLeaf),
                    euclideanDistancePt: dist,
                    isExactEnclosure: false
                )
            }
            return SyncTeXInverseMatch(
                sourceFile: smallestBox.sourceFile,
                line: smallestBox.line,
                column: smallestBox.column,
                anchor: coalescedAnchorOrFallback(for: smallestBox),
                euclideanDistancePt: 0.0,
                isExactEnclosure: true
            )
        }

        // 2. Minimum Euclidean distance across leaf/line records (falling back to all valid records)
        let pool = validRecords.filter(\.kind.isLeafOrLineLevel)
        let searchPool = pool.isEmpty ? validRecords : pool

        guard let nearest = searchPool.min(by: { lhs, rhs in
            let dL = lhs.euclideanDistance(toX: xPt, y: yPt)
            let dR = rhs.euclideanDistance(toX: xPt, y: yPt)
            if abs(dL - dR) > 1e-4 {
                return dL < dR
            }
            return lhs.areaPtSquared < rhs.areaPtSquared
        }) else {
            return nil
        }

        let dist = nearest.euclideanDistance(toX: xPt, y: yPt)
        return SyncTeXInverseMatch(
            sourceFile: nearest.sourceFile,
            line: nearest.line,
            column: nearest.column,
            anchor: coalescedAnchorOrFallback(for: nearest),
            euclideanDistancePt: dist,
            isExactEnclosure: false
        )
    }

    public func resolveInverseSearch(
        pdfPageIndex: Int,
        xPt: Double,
        yPt: Double
    ) throws -> SyncTeXInverseMatch {
        guard let hit = inverseSearch(pdfPageIndex: pdfPageIndex, xPt: xPt, yPt: yPt) else {
            throw ScholarOSError.syncTeXMappingNotFound("No SyncTeX record on PDF page index \(pdfPageIndex) near (\(xPt), \(yPt)).")
        }
        return hit
    }

    // MARK: - SyncTeX v1 State Machine Implementation

    private struct BoxStackFrame {
        let isHorizontal: Bool
        let xPt: Double
        let baselineYPt: Double
        let topYPt: Double
        let widthPt: Double
        let heightAbovePt: Double
        let depthBelowPt: Double
    }

    private static func parseSyncTeXText(_ rawText: String) throws -> SyncTeXCoordinateSolver {
        var version: Int? = nil
        var outputFmt = "pdf"
        var magnification = 1000
        var unit = 1
        var xOffsetSP = 0
        var yOffsetSP = 0
        var inputsByTag: [Int: String] = [:]

        var inContent = false
        var currentSheetPageIndex: Int? = nil
        var maxPageIndexSeen = -1
        var boxStack: [BoxStackFrame] = []
        var parsedRecords: [SyncTeXGeometricRecord] = []

        var spScale = 1.0 / 65536.0
        var xOffPt = 0.0
        var yOffPt = 0.0

        func refreshScale() {
            spScale = (Double(max(1, unit)) * (Double(max(1, magnification)) / 1000.0)) / 65536.0
            xOffPt = Double(xOffsetSP) * spScale
            yOffPt = Double(yOffsetSP) * spScale
        }

        let lines = rawText.split(whereSeparator: \.isNewline)
        for rawLineSub in lines {
            let line = String(rawLineSub)
            if line.isEmpty { continue }

            // Skip `!offset` byte markers anywhere in the file
            if line.first == "!" {
                continue
            }

            if line.hasPrefix("Postamble:") {
                break
            }

            // `Input:tag:path` can appear in preamble OR inside `Content:`
            if line.hasPrefix("Input:") {
                let rest = line.dropFirst(6)
                if let colonIdx = rest.firstIndex(of: ":"),
                   let tag = Int(rest[..<colonIdx]) {
                    let rawPath = String(rest[rest.index(after: colonIdx)...])
                    inputsByTag[tag] = normalizeSyncPath(rawPath)
                }
                continue
            }

            if !inContent {
                if line.hasPrefix("SyncTeX Version:") {
                    let vStr = line.dropFirst("SyncTeX Version:".count).trimmingCharacters(in: .whitespaces)
                    version = Int(vStr)
                } else if line.hasPrefix("Output:") {
                    outputFmt = line.dropFirst("Output:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("Magnification:") {
                    if let m = Int(line.dropFirst("Magnification:".count).trimmingCharacters(in: .whitespaces)) {
                        magnification = m
                        refreshScale()
                    }
                } else if line.hasPrefix("Unit:") {
                    if let u = Int(line.dropFirst("Unit:".count).trimmingCharacters(in: .whitespaces)) {
                        unit = u
                        refreshScale()
                    }
                } else if line.hasPrefix("X Offset:") {
                    if let xo = Int(line.dropFirst("X Offset:".count).trimmingCharacters(in: .whitespaces)) {
                        xOffsetSP = xo
                        refreshScale()
                    }
                } else if line.hasPrefix("Y Offset:") {
                    if let yo = Int(line.dropFirst("Y Offset:".count).trimmingCharacters(in: .whitespaces)) {
                        yOffsetSP = yo
                        refreshScale()
                    }
                } else if line.hasPrefix("Content:") {
                    refreshScale()
                    inContent = true
                }
                continue
            }

            // Inside `Content:` state machine
            guard let firstChar = line.first else { continue }

            switch firstChar {
            case "{":
                if let sheetNum = Int(line.dropFirst().trimmingCharacters(in: .whitespaces)) {
                    let pageIdx = max(0, sheetNum - 1)
                    currentSheetPageIndex = pageIdx
                    maxPageIndexSeen = max(maxPageIndexSeen, pageIdx)
                    boxStack.removeAll(keepingCapacity: true)
                }

            case "}":
                currentSheetPageIndex = nil
                boxStack.removeAll(keepingCapacity: true)

            case "[":
                guard let pageIdx = currentSheetPageIndex,
                      let box = parseFullBoxPayload(line.dropFirst(), scale: spScale, xOffPt: xOffPt, yOffPt: yOffPt) else {
                    continue
                }
                boxStack.append(
                    BoxStackFrame(
                        isHorizontal: false,
                        xPt: box.leftPt,
                        baselineYPt: box.baselineYPt,
                        topYPt: box.topYPt,
                        widthPt: box.widthPt,
                        heightAbovePt: box.heightAbovePt,
                        depthBelowPt: box.depthBelowPt
                    )
                )
                if let file = inputsByTag[box.tag], box.line > 0 {
                    parsedRecords.append(
                        SyncTeXGeometricRecord(
                            kind: .vbox,
                            inputTag: box.tag,
                            sourceFile: file,
                            line: box.line,
                            column: box.column,
                            pdfPageIndex: pageIdx,
                            xPt: box.leftPt,
                            yPt: box.topYPt,
                            widthPt: box.widthPt,
                            heightPt: box.totalHeightPt
                        )
                    )
                }

            case "]":
                if let idx = boxStack.lastIndex(where: { !$0.isHorizontal }) {
                    boxStack.removeSubrange(idx...)
                }

            case "(":
                guard let pageIdx = currentSheetPageIndex,
                      let box = parseFullBoxPayload(line.dropFirst(), scale: spScale, xOffPt: xOffPt, yOffPt: yOffPt) else {
                    continue
                }
                boxStack.append(
                    BoxStackFrame(
                        isHorizontal: true,
                        xPt: box.leftPt,
                        baselineYPt: box.baselineYPt,
                        topYPt: box.topYPt,
                        widthPt: box.widthPt,
                        heightAbovePt: box.heightAbovePt,
                        depthBelowPt: box.depthBelowPt
                    )
                )
                if let file = inputsByTag[box.tag], box.line > 0 {
                    parsedRecords.append(
                        SyncTeXGeometricRecord(
                            kind: .hbox,
                            inputTag: box.tag,
                            sourceFile: file,
                            line: box.line,
                            column: box.column,
                            pdfPageIndex: pageIdx,
                            xPt: box.leftPt,
                            yPt: box.topYPt,
                            widthPt: box.widthPt,
                            heightPt: box.totalHeightPt
                        )
                    )
                }

            case ")":
                if let idx = boxStack.lastIndex(where: \.isHorizontal) {
                    boxStack.removeSubrange(idx...)
                }

            case "v", "h":
                guard let pageIdx = currentSheetPageIndex,
                      let box = parseFullBoxPayload(line.dropFirst(), scale: spScale, xOffPt: xOffPt, yOffPt: yOffPt),
                      let file = inputsByTag[box.tag], box.line > 0 else {
                    continue
                }
                parsedRecords.append(
                    SyncTeXGeometricRecord(
                        kind: firstChar == "v" ? .voidVBox : .voidHBox,
                        inputTag: box.tag,
                        sourceFile: file,
                        line: box.line,
                        column: box.column,
                        pdfPageIndex: pageIdx,
                        xPt: box.leftPt,
                        yPt: box.topYPt,
                        widthPt: box.widthPt,
                        heightPt: box.totalHeightPt
                    )
                )

            case "k":
                guard let pageIdx = currentSheetPageIndex,
                      let kern = parseKernPayload(line.dropFirst(), scale: spScale, xOffPt: xOffPt, yOffPt: yOffPt),
                      let file = inputsByTag[kern.tag], kern.line > 0 else {
                    continue
                }
                let enclosing = boxStack.last(where: \.isHorizontal) ?? boxStack.last
                let hAbove = enclosing?.heightAbovePt ?? 9.5
                let dBelow = enclosing?.depthBelowPt ?? 2.5
                let left = kern.widthPt >= 0 ? kern.xPt : (kern.xPt + kern.widthPt)
                parsedRecords.append(
                    SyncTeXGeometricRecord(
                        kind: .kern,
                        inputTag: kern.tag,
                        sourceFile: file,
                        line: kern.line,
                        column: kern.column,
                        pdfPageIndex: pageIdx,
                        xPt: left,
                        yPt: kern.baselineYPt - hAbove,
                        widthPt: max(4.0, abs(kern.widthPt)),
                        heightPt: max(8.0, hAbove + dBelow)
                    )
                )

            case "x", "g", "$", "f":
                guard let pageIdx = currentSheetPageIndex,
                      let pt = parsePointLeafPayload(line.dropFirst(), scale: spScale, xOffPt: xOffPt, yOffPt: yOffPt),
                      let file = inputsByTag[pt.tag], pt.line > 0 else {
                    continue
                }
                let enclosingHBox = boxStack.last(where: \.isHorizontal)
                let hAbove = enclosingHBox?.heightAbovePt ?? 9.5
                let dBelow = enclosingHBox?.depthBelowPt ?? 2.5
                let defaultLeafWidth: Double
                if let hb = enclosingHBox, hb.widthPt > 0 {
                    defaultLeafWidth = max(12.0, min(hb.widthPt, (hb.xPt + hb.widthPt) - pt.xPt))
                } else {
                    defaultLeafWidth = 24.0
                }
                let recordKind: SyncTeXRecordKind
                switch firstChar {
                case "x": recordKind = .currentLeaf
                case "g": recordKind = .glue
                case "$": recordKind = .math
                default:  recordKind = .formRef
                }
                parsedRecords.append(
                    SyncTeXGeometricRecord(
                        kind: recordKind,
                        inputTag: pt.tag,
                        sourceFile: file,
                        line: pt.line,
                        column: pt.column,
                        pdfPageIndex: pageIdx,
                        xPt: pt.xPt,
                        yPt: pt.baselineYPt - hAbove,
                        widthPt: defaultLeafWidth,
                        heightPt: max(8.0, hAbove + dBelow)
                    )
                )

            default:
                continue
            }
        }

        guard version != nil || inContent else {
            throw ScholarOSError.syncTeXMappingNotFound("Invalid SyncTeX header: missing 'SyncTeX Version:1' or 'Content:' section.")
        }

        let preamble = SyncTeXPreamble(
            version: version ?? 1,
            outputFormat: outputFmt,
            magnification: magnification,
            unit: unit,
            xOffsetSP: xOffsetSP,
            yOffsetSP: yOffsetSP,
            inputsByTag: inputsByTag
        )
        return SyncTeXCoordinateSolver(
            preamble: preamble,
            pageCount: max(0, maxPageIndexSeen + 1),
            records: parsedRecords
        )
    }

    // MARK: - SyncTeX Payload Parsers

    private struct ParsedBoxRecord {
        let tag: Int
        let line: Int
        let column: Int
        let leftPt: Double
        let baselineYPt: Double
        let topYPt: Double
        let widthPt: Double
        let heightAbovePt: Double
        let depthBelowPt: Double
        var totalHeightPt: Double { max(8.0, heightAbovePt + depthBelowPt) }
    }

    private static func parseFullBoxPayload(
        _ slice: Substring,
        scale: Double,
        xOffPt: Double,
        yOffPt: Double
    ) -> ParsedBoxRecord? {
        // Format: `<tag>,<line>(,<col>)?:<x>,<y>:<W>,<H>,<D>`
        let groups = slice.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count >= 3 else { return nil }
        guard let (tag, line, col) = parseTagLineCol(groups[0]),
              let (xSP, ySP) = parsePairInts(groups[1]),
              let (wSP, hSP, dSP) = parseTripleInts(groups[2]) else {
            return nil
        }
        let xPt = xOffPt + Double(xSP) * scale
        let baseYPt = yOffPt + Double(ySP) * scale
        let wPt = abs(Double(wSP) * scale)
        let hPt = max(0.0, Double(hSP) * scale)
        let dPt = max(0.0, Double(dSP) * scale)
        return ParsedBoxRecord(
            tag: tag,
            line: line,
            column: col,
            leftPt: xPt,
            baselineYPt: baseYPt,
            topYPt: baseYPt - hPt,
            widthPt: wPt,
            heightAbovePt: hPt,
            depthBelowPt: dPt
        )
    }

    private static func parseKernPayload(
        _ slice: Substring,
        scale: Double,
        xOffPt: Double,
        yOffPt: Double
    ) -> (tag: Int, line: Int, column: Int, xPt: Double, baselineYPt: Double, widthPt: Double)? {
        // Format: `<tag>,<line>(,<col>)?:<x>,<y>:<W>`
        let groups = slice.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count >= 3,
              let (tag, line, col) = parseTagLineCol(groups[0]),
              let (xSP, ySP) = parsePairInts(groups[1]),
              let wSP = Int(groups[2].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (
            tag,
            line,
            col,
            xOffPt + Double(xSP) * scale,
            yOffPt + Double(ySP) * scale,
            Double(wSP) * scale
        )
    }

    private static func parsePointLeafPayload(
        _ slice: Substring,
        scale: Double,
        xOffPt: Double,
        yOffPt: Double
    ) -> (tag: Int, line: Int, column: Int, xPt: Double, baselineYPt: Double)? {
        // Format: `<tag>,<line>(,<col>)?:<x>,<y>`
        let groups = slice.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.count >= 2,
              let (tag, line, col) = parseTagLineCol(groups[0]),
              let (xSP, ySP) = parsePairInts(groups[1]) else {
            return nil
        }
        return (
            tag,
            line,
            col,
            xOffPt + Double(xSP) * scale,
            yOffPt + Double(ySP) * scale
        )
    }

    private static func parseTagLineCol(_ part: Substring) -> (Int, Int, Int)? {
        let nums = part.split(separator: ",")
        guard nums.count >= 2,
              let tag = Int(nums[0]),
              let line = Int(nums[1]) else {
            return nil
        }
        let col = (nums.count >= 3 ? Int(nums[2]) : nil) ?? 1
        return (tag, line, max(1, col))
    }

    private static func parsePairInts(_ part: Substring) -> (Int, Int)? {
        let nums = part.split(separator: ",")
        guard nums.count >= 2,
              let a = Int(nums[0]),
              let b = Int(nums[1]) else {
            return nil
        }
        return (a, b)
    }

    private static func parseTripleInts(_ part: Substring) -> (Int, Int, Int)? {
        let nums = part.split(separator: ",")
        guard nums.count >= 3,
              let a = Int(nums[0]),
              let b = Int(nums[1]),
              let c = Int(nums[2]) else {
            return nil
        }
        return (a, b, c)
    }

    // MARK: - Line Anchor Coalescing & Path Matching

    private static func buildCoalescedLineAnchors(from records: [SyncTeXGeometricRecord]) -> [SyncTeXAnchor] {
        struct LinePageKey: Hashable {
            let file: String
            let line: Int
            let page: Int
        }

        // Group leaf/line records first; only use vbox records for `(file, line, page)` tuples lacking leaf/hbox records
        var grouped: [LinePageKey: [SyncTeXGeometricRecord]] = [:]
        for rec in records where rec.line >= 1 && !rec.sourceFile.isEmpty && rec.kind.isLeafOrLineLevel {
            let key = LinePageKey(file: rec.sourceFile, line: rec.line, page: rec.pdfPageIndex)
            grouped[key, default: []].append(rec)
        }
        for rec in records where rec.line >= 1 && !rec.sourceFile.isEmpty && !rec.kind.isLeafOrLineLevel {
            let key = LinePageKey(file: rec.sourceFile, line: rec.line, page: rec.pdfPageIndex)
            if grouped[key] == nil {
                grouped[key] = [rec]
            }
        }

        var anchors: [SyncTeXAnchor] = []
        anchors.reserveCapacity(grouped.count)

        for (key, group) in grouped {
            guard let first = group.first else { continue }
            var minX = first.xPt
            var minY = first.yPt
            var maxX = first.xPt + max(8.0, first.widthPt)
            var maxY = first.yPt + max(8.0, first.heightPt)
            var minCol = first.column

            for item in group.dropFirst() {
                minX = min(minX, item.xPt)
                minY = min(minY, item.yPt)
                maxX = max(maxX, item.xPt + max(8.0, item.widthPt))
                maxY = max(maxY, item.yPt + max(8.0, item.heightPt))
                minCol = min(minCol, item.column)
            }

            anchors.append(
                SyncTeXAnchor(
                    sourceFile: key.file,
                    line: key.line,
                    column: minCol,
                    pdfPageIndex: key.page,
                    xPt: minX,
                    yPt: minY,
                    widthPt: max(16.0, maxX - minX),
                    heightPt: max(10.0, maxY - minY)
                )
            )
        }

        return anchors.sorted { lhs, rhs in
            if lhs.pdfPageIndex != rhs.pdfPageIndex { return lhs.pdfPageIndex < rhs.pdfPageIndex }
            if abs(lhs.yPt - rhs.yPt) > 0.5 { return lhs.yPt < rhs.yPt }
            return lhs.line < rhs.line
        }
    }

    private func coalescedAnchorOrFallback(for record: SyncTeXGeometricRecord) -> SyncTeXAnchor {
        let norm = Self.normalizeSyncPath(record.sourceFile)
        if let lineAnchor = anchorsByNormalizedFile[norm]?.first(where: { $0.line == record.line && $0.pdfPageIndex == record.pdfPageIndex }) {
            return lineAnchor
        }
        return record.toAnchor()
    }

    private func resolveMatchingFileKey(for requestedFile: String) -> String? {
        let normReq = Self.normalizeSyncPath(requestedFile)
        if anchorsByNormalizedFile[normReq] != nil {
            return normReq
        }
        // Suffix match (e.g. `sections/methods.tex` matching `/Users/x/proj/sections/methods.tex`)
        for candidate in anchorsByNormalizedFile.keys.sorted() {
            if candidate.hasSuffix("/" + normReq) || normReq.hasSuffix("/" + candidate) {
                return candidate
            }
        }
        // Try adding `.tex` if omitted in LaTeX `\input{sections/methods}`
        if !normReq.contains(".") {
            let withTex = normReq + ".tex"
            if anchorsByNormalizedFile[withTex] != nil {
                return withTex
            }
            for candidate in anchorsByNormalizedFile.keys.sorted() where candidate.hasSuffix("/" + withTex) {
                return candidate
            }
        }
        // Unambiguous basename fallback
        let reqBase = (normReq as NSString).lastPathComponent
        let baseMatches = anchorsByNormalizedFile.keys.filter { ($0 as NSString).lastPathComponent == reqBase }
        if baseMatches.count == 1 {
            return baseMatches[0]
        }
        return nil
    }

    static func normalizeSyncPath(_ raw: String) -> String {
        let slashed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let isAbs = slashed.hasPrefix("/")
        var stack: [Substring] = []
        for part in slashed.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbs {
                    stack.append("..")
                }
            } else {
                stack.append(part)
            }
        }
        let joined = stack.joined(separator: "/")
        return isAbs ? ("/" + joined) : joined
    }
}

// MARK: - Deterministic AST-Driven Synthetic SyncTeX v1 Builder (US Letter 612 x 792 pt)

public struct SyntheticSyncTeXBuilder: Sendable {
    public static let usLetterWidthPt: Double = 612.0
    public static let usLetterHeightPt: Double = 792.0
    public static let scaledPointsPerPDFPoint: Double = 65536.0

    public let pageWidthPt: Double
    public let pageHeightPt: Double
    public let marginLeftPt: Double
    public let marginRightPt: Double
    public let marginTopPt: Double
    public let marginBottomPt: Double

    public var contentWidthPt: Double {
        max(120.0, pageWidthPt - marginLeftPt - marginRightPt)
    }

    public init(
        pageWidthPt: Double = SyntheticSyncTeXBuilder.usLetterWidthPt,
        pageHeightPt: Double = SyntheticSyncTeXBuilder.usLetterHeightPt,
        marginLeftPt: Double = 72.0,
        marginRightPt: Double = 72.0,
        marginTopPt: Double = 72.0,
        marginBottomPt: Double = 72.0
    ) {
        self.pageWidthPt = pageWidthPt
        self.pageHeightPt = pageHeightPt
        self.marginLeftPt = marginLeftPt
        self.marginRightPt = marginRightPt
        self.marginTopPt = marginTopPt
        self.marginBottomPt = marginBottomPt
    }

    /// Generates an uncompressed SyncTeX v1 string directly from `MergedManuscriptWorkspaceAST`.
    public func buildSyncTeXString(from workspace: MergedManuscriptWorkspaceAST) -> String {
        // Assign deterministic 1-based `Input:tag:path` tags for every manuscript file in reading order
        var orderedFiles = workspace.includeGraph.documentReadingOrder
        if orderedFiles.isEmpty {
            orderedFiles = [workspace.includeGraph.rootFilePath]
        }
        var tagByFile: [String: Int] = [:]
        for (idx, path) in orderedFiles.enumerated() {
            tagByFile[SyncTeXCoordinateSolver.normalizeSyncPath(path)] = idx + 1
        }

        func tag(for filePath: String) -> Int {
            let norm = SyncTeXCoordinateSolver.normalizeSyncPath(filePath)
            if let existing = tagByFile[norm] { return existing }
            let nextTag = tagByFile.count + 1
            tagByFile[norm] = nextTag
            orderedFiles.append(norm)
            return nextTag
        }

        func toSP(_ pt: Double) -> Int {
            Int((pt * Self.scaledPointsPerPDFPoint).rounded())
        }

        struct EmittedSheet {
            let sheetNumber: Int
            let rootTag: Int
            var records: [String]
        }

        let rootTag = tag(for: workspace.includeGraph.rootFilePath)
        var sheets: [EmittedSheet] = []
        var currentSheet = EmittedSheet(sheetNumber: 1, rootTag: rootTag, records: [])
        var cursorY = marginTopPt
        let maxY = pageHeightPt - marginBottomPt
        var totalRecordCount = 0

        func ensureVerticalRoom(_ neededHeightPt: Double) {
            if cursorY + neededHeightPt > maxY && !currentSheet.records.isEmpty {
                sheets.append(currentSheet)
                currentSheet = EmittedSheet(sheetNumber: sheets.count + 1, rootTag: rootTag, records: [])
                cursorY = marginTopPt
            }
        }

        func emitLineBoxAndLeaf(
            fileTag: Int,
            line: Int,
            column: Int = 1,
            xPt: Double,
            topYPt: Double,
            widthPt: Double,
            heightAbovePt: Double,
            depthBelowPt: Double,
            leafOp: Character = "x"
        ) {
            let safeLine = max(1, line)
            let safeCol = max(1, column)
            let baselineY = topYPt + heightAbovePt
            let xSP = toSP(xPt)
            let baseSP = toSP(baselineY)
            let wSP = toSP(max(12.0, widthPt))
            let hSP = toSP(max(6.0, heightAbovePt))
            let dSP = toSP(max(1.5, depthBelowPt))

            currentSheet.records.append("(\(fileTag),\(safeLine),\(safeCol):\(xSP),\(baseSP):\(wSP),\(hSP),\(dSP)")
            currentSheet.records.append("\(leafOp)\(fileTag),\(safeLine),\(safeCol):\(xSP),\(baseSP)")
            let endXSP = toSP(xPt + max(12.0, widthPt))
            currentSheet.records.append("g\(fileTag),\(safeLine),\(safeCol):\(endXSP),\(baseSP)")
            currentSheet.records.append(")")
            totalRecordCount += 3
        }

        func layoutASTSubtree(_ node: MarkupASTNode) {
            let fileTag = tag(for: node.span.filePath)
            let startLine = max(1, node.span.start.line)
            let endLine = max(startLine, node.span.end.line)

            switch node.kind {
            case .document:
                for child in node.children {
                    layoutASTSubtree(child)
                }

            case .section(let level, let title, _):
                let fontHeight: Double = (level <= 1) ? 16.0 : (level == 2 ? 13.5 : 11.5)
                let spacingBefore: Double = (level <= 1) ? 14.0 : 10.0
                let spacingAfter: Double = 6.0
                ensureVerticalRoom(spacingBefore + fontHeight + 4.0 + spacingAfter)
                cursorY += spacingBefore
                let estWidth = min(contentWidthPt, max(90.0, Double(title.count) * (fontHeight * 0.52)))
                emitLineBoxAndLeaf(
                    fileTag: fileTag,
                    line: startLine,
                    column: node.span.start.column,
                    xPt: marginLeftPt,
                    topYPt: cursorY,
                    widthPt: estWidth,
                    heightAbovePt: fontHeight,
                    depthBelowPt: 3.5
                )
                cursorY += fontHeight + 3.5 + spacingAfter
                for child in node.children {
                    layoutASTSubtree(child)
                }

            case .paragraph(let preview):
                let approxChars = max(40, preview.count)
                let charsPerVisualLine = 78
                let visualLineCount = max(1, (approxChars + charsPerVisualLine - 1) / charsPerVisualLine)
                let sourceLineSpan = max(1, endLine - startLine + 1)
                let totalSteps = max(visualLineCount, sourceLineSpan)
                let lineHeight = 13.5

                for step in 0..<totalSteps {
                    ensureVerticalRoom(lineHeight)
                    let mappedSourceLine = min(
                        endLine,
                        startLine + Int((Double(step) / Double(max(1, totalSteps - 1)) * Double(sourceLineSpan - 1)).rounded())
                    )
                    let isLastVisualLine = (step == totalSteps - 1)
                    let lineWidth = isLastVisualLine ? min(contentWidthPt, max(140.0, contentWidthPt * 0.68)) : contentWidthPt
                    emitLineBoxAndLeaf(
                        fileTag: fileTag,
                        line: mappedSourceLine,
                        column: step == 0 ? node.span.start.column : 1,
                        xPt: marginLeftPt,
                        topYPt: cursorY,
                        widthPt: lineWidth,
                        heightAbovePt: 10.0,
                        depthBelowPt: 2.5
                    )
                    cursorY += lineHeight
                }
                cursorY += 5.0 // Paragraph skip
                // Also record inline citation/math/crossRef child anchors along the paragraph if any
                for child in node.children {
                    if case .mathExpression(let isDisp, _, _) = child.kind, isDisp {
                        layoutASTSubtree(child)
                    }
                }

            case .mathExpression(let isDisplayMode, let formulaSource, _):
                if isDisplayMode {
                    let eqLines = max(1, formulaSource.split(whereSeparator: \.isNewline).count)
                    let blockHeight = Double(eqLines) * 18.0 + 10.0
                    ensureVerticalRoom(blockHeight + 8.0)
                    cursorY += 4.0
                    let eqWidth = min(contentWidthPt * 0.82, max(120.0, Double(formulaSource.count) * 4.8))
                    let centeredX = marginLeftPt + (contentWidthPt - eqWidth) * 0.5

                    for idx in 0..<eqLines {
                        let ln = min(endLine, startLine + idx)
                        emitLineBoxAndLeaf(
                            fileTag: fileTag,
                            line: ln,
                            column: 1,
                            xPt: centeredX,
                            topYPt: cursorY,
                            widthPt: eqWidth,
                            heightAbovePt: 13.5,
                            depthBelowPt: 4.5,
                            leafOp: "$"
                        )
                        cursorY += 18.0
                    }
                    cursorY += 6.0
                }

            case .environment(let envName, _, let caption):
                let lower = envName.lowercased()
                if lower.hasPrefix("equation") || lower.hasPrefix("align") || lower.hasPrefix("gather") || lower.hasPrefix("multline") {
                    let hasDisplayChild = node.children.contains {
                        if case .mathExpression(let d, _, _) = $0.kind { return d }
                        return false
                    }
                    if hasDisplayChild {
                        for child in node.children { layoutASTSubtree(child) }
                    } else {
                        let spanLines = max(1, min(8, endLine - startLine + 1))
                        ensureVerticalRoom(Double(spanLines) * 17.0 + 8.0)
                        for step in 0..<spanLines {
                            emitLineBoxAndLeaf(
                                fileTag: fileTag,
                                line: startLine + step,
                                xPt: marginLeftPt + 36.0,
                                topYPt: cursorY,
                                widthPt: contentWidthPt - 72.0,
                                heightAbovePt: 12.5,
                                depthBelowPt: 4.0,
                                leafOp: "$"
                            )
                            cursorY += 17.0
                        }
                    }
                } else if lower.hasPrefix("figure") || lower.hasPrefix("table") || lower.hasPrefix("algorithm") {
                    let floatBoxHeight: Double = lower.hasPrefix("figure") ? 132.0 : 96.0
                    ensureVerticalRoom(floatBoxHeight + 28.0)
                    cursorY += 8.0

                    // Graphic / tabular visual frame mapped to `startLine`
                    let frameBaseSP = toSP(cursorY + floatBoxHeight - 18.0)
                    currentSheet.records.append(
                        "v\(fileTag),\(startLine),1:\(toSP(marginLeftPt)),\(frameBaseSP):\(toSP(contentWidthPt)),\(toSP(floatBoxHeight - 18.0)),\(toSP(4.0))"
                    )
                    totalRecordCount += 1
                    cursorY += floatBoxHeight - 14.0

                    // Caption / bottom lines mapped cleanly up to `endLine`
                    let capLine = max(startLine, endLine - 1)
                    let capWidth = min(contentWidthPt, max(180.0, Double((caption ?? envName).count) * 5.2))
                    emitLineBoxAndLeaf(
                        fileTag: fileTag,
                        line: capLine,
                        xPt: marginLeftPt,
                        topYPt: cursorY,
                        widthPt: capWidth,
                        heightAbovePt: 9.5,
                        depthBelowPt: 2.5
                    )
                    cursorY += 18.0
                } else {
                    if node.children.isEmpty {
                        ensureVerticalRoom(16.0)
                        emitLineBoxAndLeaf(
                            fileTag: fileTag,
                            line: startLine,
                            xPt: marginLeftPt + 14.0,
                            topYPt: cursorY,
                            widthPt: contentWidthPt - 28.0,
                            heightAbovePt: 10.0,
                            depthBelowPt: 2.5
                        )
                        cursorY += 15.0
                    } else {
                        for child in node.children {
                            layoutASTSubtree(child)
                        }
                    }
                }

            case .labelDeclaration, .citation, .crossReference, .fileInclude, .macroDefinition, .syntaxErrorRecovery:
                ensureVerticalRoom(14.0)
                emitLineBoxAndLeaf(
                    fileTag: fileTag,
                    line: startLine,
                    column: node.span.start.column,
                    xPt: marginLeftPt,
                    topYPt: cursorY,
                    widthPt: min(contentWidthPt, 220.0),
                    heightAbovePt: 10.0,
                    depthBelowPt: 2.5
                )
                cursorY += 4.0
            }
        }

        layoutASTSubtree(workspace.mergedRootAST)

        // Guarantee at least one page anchor even for an empty buffer!
        if currentSheet.records.isEmpty && sheets.isEmpty {
            emitLineBoxAndLeaf(
                fileTag: rootTag,
                line: 1,
                column: 1,
                xPt: marginLeftPt,
                topYPt: marginTopPt,
                widthPt: contentWidthPt,
                heightAbovePt: 10.0,
                depthBelowPt: 2.5
            )
        }
        if !currentSheet.records.isEmpty {
            sheets.append(currentSheet)
        }

        var outLines: [String] = []
        outLines.reserveCapacity(32 + sheets.reduce(0) { $0 + $1.records.count + 6 })
        outLines.append("SyncTeX Version:1")
        for (normPath, assignedTag) in tagByFile.sorted(by: { $0.value < $1.value }) {
            outLines.append("Input:\(assignedTag):\(normPath)")
        }
        outLines.append("Output:pdf")
        outLines.append("Magnification:1000")
        outLines.append("Unit:1")
        outLines.append("X Offset:0")
        outLines.append("Y Offset:0")
        outLines.append("Content:")

        let pageWSP = toSP(pageWidthPt)
        let pageHSP = toSP(pageHeightPt)

        for sheet in sheets {
            outLines.append("{\(sheet.sheetNumber)")
            outLines.append("[\(sheet.rootTag),1:0,\(pageHSP):\(pageWSP),\(pageHSP),0")
            outLines.append(contentsOf: sheet.records)
            outLines.append("]")
            outLines.append("}")
        }

        outLines.append("Postamble:")
        outLines.append("Count:\(totalRecordCount)")
        outLines.append("Post scriptum:")
        return outLines.joined(separator: "\n") + "\n"
    }

    /// Generates gzip-compressed `.synctex.gz` (or uncompressed `.synctex`) payload `Data` from a workspace AST.
    public func buildSyncTeXData(
        from workspace: MergedManuscriptWorkspaceAST,
        compressed: Bool = true
    ) throws -> Data {
        let rawText = buildSyncTeXString(from: workspace)
        let utf8Data = Data(rawText.utf8)
        if compressed {
            return try SyncTeXZlibCodec.compressGzip(utf8Data)
        }
        return utf8Data
    }

    /// Builds a ready-to-query `SyncTeXCoordinateSolver` directly from `MergedManuscriptWorkspaceAST`.
    public func buildSolver(from workspace: MergedManuscriptWorkspaceAST) throws -> SyncTeXCoordinateSolver {
        let rawText = buildSyncTeXString(from: workspace)
        return try SyncTeXCoordinateSolver(syncTeXString: rawText)
    }
}
