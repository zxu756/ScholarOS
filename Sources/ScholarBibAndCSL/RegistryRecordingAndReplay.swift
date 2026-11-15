import CryptoKit
import Foundation

// MARK: - Fatal Session Error Marker

/// Marker protocol for session errors that must abort a recording or replay run immediately
/// rather than being downgraded into an `UNVERIFIED` transport fallback.
public protocol FatalRegistrySessionError: Error, LocalizedError, Sendable {}

// MARK: - Recording & Replay Errors

public enum RegistryRecordingError: FatalRegistrySessionError, Equatable {
    case invalidRequestURL(String)
    case disallowedHost(String)
    case unsupportedHTTPMethod(String)
    case sensitiveDataInRequest(String)
    case requestBudgetExceeded(limit: Int, url: String)
    case rateLimited(url: String, retryAfter: String?)
    case unexpectedServerStatus(statusCode: Int, url: String)
    case slugCollision(slug: String, existingURL: String, newURL: String)
    case corruptExistingDirectory(String)
    case transportFailed(url: String, detail: String)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequestURL(let detail):
            return "Invalid registry request URL: \(detail)"
        case .disallowedHost(let host):
            return "Disallowed registry host '\(host)' during recording."
        case .unsupportedHTTPMethod(let method):
            return "Unsupported HTTP method '\(method)' for registry recording; only GET is allowed."
        case .sensitiveDataInRequest(let detail):
            return "Sensitive or forbidden token in registry request: \(detail)"
        case .requestBudgetExceeded(let limit, let url):
            return "Registry recording request limit (\(limit)) exceeded before requesting \(url)."
        case .rateLimited(let url, let retryAfter):
            let retrySuffix = retryAfter.map { " (Retry-After: \($0))" } ?? ""
            return "Registry returned HTTP 429 for \(url)\(retrySuffix); stopping recording immediately."
        case .unexpectedServerStatus(let statusCode, let url):
            return "Registry returned server error HTTP \(statusCode) for \(url) during recording."
        case .slugCollision(let slug, let existingURL, let newURL):
            return "Recording slug collision '\(slug)' between '\(existingURL)' and '\(newURL)'."
        case .corruptExistingDirectory(let detail):
            return "Existing recording directory failed integrity check: \(detail)"
        case .transportFailed(let url, let detail):
            return "Registry transport failed while recording \(url): \(detail)"
        case .ioFailure(let detail):
            return "Recording file I/O failed: \(detail)"
        }
    }
}

public enum RegistryReplayError: FatalRegistrySessionError, Equatable {
    case missingDirectory(String)
    case missingManifest(String)
    case corruptManifest(String)
    case missingRawFile(file: String, url: String)
    case missingMetaFile(file: String, url: String)
    case corruptMetaFile(file: String, detail: String)
    case checksumMismatch(file: String, expected: String, actual: String)
    case byteLengthMismatch(file: String, expected: Int, actual: Int)
    case unrecordedRequest(url: String)

    public var errorDescription: String? {
        switch self {
        case .missingDirectory(let path):
            return "Registry replay directory does not exist or is not a directory: \(path)"
        case .missingManifest(let path):
            return "Registry replay manifest.json is missing at: \(path)"
        case .corruptManifest(let detail):
            return "Registry replay manifest.json is invalid: \(detail)"
        case .missingRawFile(let file, let url):
            return "Registry replay missing raw fixture '\(file)' for recorded URL \(url)"
        case .missingMetaFile(let file, let url):
            return "Registry replay missing metadata fixture '\(file)' for recorded URL \(url)"
        case .corruptMetaFile(let file, let detail):
            return "Registry replay metadata fixture '\(file)' is invalid: \(detail)"
        case .checksumMismatch(let file, let expected, let actual):
            return "Registry replay SHA-256 mismatch for '\(file)': expected \(expected), got \(actual)"
        case .byteLengthMismatch(let file, let expected, let actual):
            return "Registry replay byte_length mismatch for '\(file)': expected \(expected), got \(actual)"
        case .unrecordedRequest(let url):
            return "Registry replay miss — unrecorded request URL: \(url)"
        }
    }
}

// MARK: - Manifest & Metadata Models

public struct RegistryRecordedItem: Codable, Sendable, Equatable {
    public let slug: String
    public let service: String
    public let url: String
    public let status: Int
    public let contentType: String
    public let requestedAt: String
    public let responseDateHeader: String
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let rawFile: String
    public let byteLength: Int
    public let sha256: String
    public let attempts: Int

    public init(
        slug: String,
        service: String,
        url: String,
        status: Int,
        contentType: String,
        requestedAt: String,
        responseDateHeader: String,
        requestHeaders: [String: String],
        responseHeaders: [String: String],
        rawFile: String,
        byteLength: Int,
        sha256: String,
        attempts: Int
    ) {
        self.slug = slug
        self.service = service
        self.url = url
        self.status = status
        self.contentType = contentType
        self.requestedAt = requestedAt
        self.responseDateHeader = responseDateHeader
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.rawFile = rawFile
        self.byteLength = byteLength
        self.sha256 = sha256
        self.attempts = attempts
    }

    enum CodingKeys: String, CodingKey {
        case slug
        case service
        case url
        case status
        case contentType = "content_type"
        case requestedAt = "requested_at"
        case responseDateHeader = "response_date_header"
        case requestHeaders = "request_headers"
        case responseHeaders = "response_headers"
        case rawFile = "raw_file"
        case byteLength = "byte_length"
        case sha256
        case attempts
    }
}

public struct RegistryRecordingManifest: Codable, Sendable, Equatable {
    public let startedAt: String
    public let completedAt: String
    public let userAgent: String
    public let count: Int
    public let totalHTTPRequestsSent: Int
    public let items: [RegistryRecordedItem]
    public let metaFilesSHA256: [String: String]?

    public init(
        startedAt: String,
        completedAt: String,
        userAgent: String,
        count: Int,
        totalHTTPRequestsSent: Int,
        items: [RegistryRecordedItem],
        metaFilesSHA256: [String: String]? = nil
    ) {
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.userAgent = userAgent
        self.count = count
        self.totalHTTPRequestsSent = totalHTTPRequestsSent
        self.items = items
        self.metaFilesSHA256 = metaFilesSHA256
    }

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case userAgent = "user_agent"
        case count
        case totalHTTPRequestsSent = "total_http_requests_sent"
        case items
        case metaFilesSHA256 = "meta_files_sha256"
    }
}

// MARK: - Canonical URL, Service & Slug Helper

public enum RegistryCanonicalURL: Sendable {
    public static let allowedHosts: [String: String] = [
        "api.crossref.org": "crossref",
        "api.openalex.org": "openalex",
        "doi.org": "doi",
        "export.arxiv.org": "arxiv",
        "eutils.ncbi.nlm.nih.gov": "pubmed"
    ]

    private static let forbiddenParameterSubstrings: [String] = [
        String(["m", "a", "i", "l", "t", "o"]),
        String(["p", "o", "l", "i", "t", "e", "m", "a", "i", "l", "t", "o"]),
        String(["a", "p", "i", "_", "k", "e", "y"]),
        String(["a", "p", "i", "k", "e", "y"]),
        "access_token",
        "client_secret"
    ]

    private static let forbiddenPathPrefixes: [String] = [
        "/" + String(["u", "s", "e", "r", "s"]) + "/",
        "/" + String(["h", "o", "m", "e"]) + "/",
        "/" + String(["v", "a", "r", "/", "f", "o", "l", "d", "e", "r", "s"]) + "/",
        "/" + String(["p", "r", "i", "v", "a", "t", "e", "/", "v", "a", "r"]) + "/",
        "/" + String(["t", "m", "p"]) + "/",
        "file://"
    ]

    private static let forbiddenExactQueryNames: Set<String> = [
        "key",
        "token",
        "auth",
        "email",
        "contact"
    ]

    public static func normalizeForRecording(_ url: URL) throws -> (canonicalURL: String, service: String) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw RegistryRecordingError.invalidRequestURL(url.absoluteString)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "https" else {
            throw RegistryRecordingError.invalidRequestURL("Only https scheme is permitted: \(url.absoluteString)")
        }
        if components.user != nil || components.password != nil {
            throw RegistryRecordingError.sensitiveDataInRequest("URL credentials are forbidden.")
        }
        guard let rawHost = components.host?.lowercased(), !rawHost.isEmpty else {
            throw RegistryRecordingError.invalidRequestURL("Missing host in \(url.absoluteString)")
        }
        guard let service = allowedHosts[rawHost] else {
            throw RegistryRecordingError.disallowedHost(rawHost)
        }
        if let port = components.port, port != 443 {
            throw RegistryRecordingError.invalidRequestURL("Non-standard port \(port) is not permitted.")
        }

        components.scheme = "https"
        components.host = rawHost
        components.port = nil
        components.fragment = nil

        let normalizedPath = uppercasePercentEscapes(in: components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
        components.percentEncodedPath = normalizedPath

        if let rawItems = components.percentEncodedQueryItems {
            if rawItems.isEmpty {
                components.percentEncodedQuery = nil
            } else {
                var normalizedItems: [URLQueryItem] = []
                normalizedItems.reserveCapacity(rawItems.count)
                for item in rawItems {
                    let normName = uppercasePercentEscapes(in: item.name)
                    let decodedName = (normName.removingPercentEncoding ?? normName).lowercased()
                    if forbiddenExactQueryNames.contains(decodedName) {
                        throw RegistryRecordingError.sensitiveDataInRequest("Forbidden query parameter '\(decodedName)'.")
                    }
                    let normVal = item.value.map { uppercasePercentEscapes(in: $0) }
                    normalizedItems.append(URLQueryItem(name: normName, value: normVal))
                }
                normalizedItems.sort { lhs, rhs in
                    if lhs.name != rhs.name {
                        return lhs.name < rhs.name
                    }
                    return (lhs.value ?? "") < (rhs.value ?? "")
                }
                components.percentEncodedQueryItems = normalizedItems
            }
        }

        guard let canonical = components.string else {
            throw RegistryRecordingError.invalidRequestURL(url.absoluteString)
        }
        try validateNoSensitiveContent(inURLString: canonical)
        return (canonical, service)
    }

    public static func normalizeForReplay(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else {
            return url.absoluteString
        }
        components.scheme = scheme
        components.host = rawHost
        if components.port == 443 || components.port == 80 {
            components.port = nil
        }
        components.fragment = nil
        components.percentEncodedPath = uppercasePercentEscapes(
            in: components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        )
        if let rawItems = components.percentEncodedQueryItems {
            if rawItems.isEmpty {
                components.percentEncodedQuery = nil
            } else {
                var normalizedItems = rawItems.map {
                    URLQueryItem(
                        name: uppercasePercentEscapes(in: $0.name),
                        value: $0.value.map { uppercasePercentEscapes(in: $0) }
                    )
                }
                normalizedItems.sort { lhs, rhs in
                    if lhs.name != rhs.name {
                        return lhs.name < rhs.name
                    }
                    return (lhs.value ?? "") < (rhs.value ?? "")
                }
                components.percentEncodedQueryItems = normalizedItems
            }
        }
        return components.string ?? url.absoluteString
    }

    public static func validateNoSensitiveContent(inURLString urlString: String) throws {
        let candidates = [urlString, urlString.removingPercentEncoding ?? urlString]
        let homeLower = NSHomeDirectory().lowercased()

        for candidate in candidates {
            let lower = candidate.lowercased()
            if lower.contains("@") || lower.contains("%40") {
                throw RegistryRecordingError.sensitiveDataInRequest("Email or '@' character in request URL.")
            }
            for token in forbiddenParameterSubstrings where lower.contains(token) {
                throw RegistryRecordingError.sensitiveDataInRequest("Forbidden parameter token in request URL.")
            }
            for pathPrefix in forbiddenPathPrefixes where lower.contains(pathPrefix) {
                throw RegistryRecordingError.sensitiveDataInRequest("Local filesystem path in request URL.")
            }
            if !homeLower.isEmpty && homeLower != "/" && lower.contains(homeLower) {
                throw RegistryRecordingError.sensitiveDataInRequest("Home directory path in request URL.")
            }
        }
    }

    public static func validateRequestHeaders(_ headers: [String: String], expectedUserAgent: String) throws {
        let homeLower = NSHomeDirectory().lowercased()
        for (rawKey, rawValue) in headers {
            let lowerKey = rawKey.lowercased()
            let decodedVal = rawValue.removingPercentEncoding ?? rawValue
            let lowerVal = decodedVal.lowercased()

            if lowerKey == "authorization" || lowerKey.contains("token") || lowerKey.contains("cookie") {
                throw RegistryRecordingError.sensitiveDataInRequest("Forbidden authentication header '\(rawKey)'.")
            }
            for token in forbiddenParameterSubstrings {
                if lowerKey.contains(token) || lowerVal.contains(token) {
                    throw RegistryRecordingError.sensitiveDataInRequest("Forbidden credential token in header '\(rawKey)'.")
                }
            }
            if lowerVal.contains("@") || rawValue.lowercased().contains("%40") {
                throw RegistryRecordingError.sensitiveDataInRequest("Email or '@' character in header '\(rawKey)'.")
            }
            for pathPrefix in forbiddenPathPrefixes where lowerVal.contains(pathPrefix) {
                throw RegistryRecordingError.sensitiveDataInRequest("Local filesystem path in header '\(rawKey)'.")
            }
            if !homeLower.isEmpty && homeLower != "/" && lowerVal.contains(homeLower) {
                throw RegistryRecordingError.sensitiveDataInRequest("Home directory path in header '\(rawKey)'.")
            }
            if lowerKey == "user-agent" {
                if rawValue != expectedUserAgent {
                    throw RegistryRecordingError.sensitiveDataInRequest("Unexpected User-Agent '\(rawValue)'.")
                }
                if lowerVal.contains("http://") || lowerVal.contains("https://") {
                    throw RegistryRecordingError.sensitiveDataInRequest("URL is forbidden in User-Agent.")
                }
            }
        }
    }

    public static func computeSlug(forNormalizedURL canonicalURL: String) throws -> String {
        guard let url = URL(string: canonicalURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let service = allowedHosts[host] else {
            throw RegistryRecordingError.invalidRequestURL(canonicalURL)
        }

        let path = components.path
        let queryItems = components.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        let kind: String
        let rawLabel: String

        switch service {
        case "crossref":
            if path.hasPrefix("/works/") && path.count > "/works/".count {
                kind = "doi"
                rawLabel = String(path.dropFirst("/works/".count))
            } else if let bibQuery = queryValue("query.bibliographic") {
                kind = "title"
                rawLabel = bibQuery
            } else {
                kind = "query"
                rawLabel = path
            }
        case "openalex":
            if path.hasPrefix("/works/https://doi.org/") {
                kind = "doi"
                rawLabel = String(path.dropFirst("/works/https://doi.org/".count))
            } else if let searchQuery = queryValue("search") {
                kind = "title"
                rawLabel = searchQuery
            } else {
                kind = "work"
                rawLabel = path
            }
        case "doi":
            if path.hasPrefix("/api/handles/") && path.count > "/api/handles/".count {
                kind = "handle"
                rawLabel = String(path.dropFirst("/api/handles/".count))
            } else {
                kind = "path"
                rawLabel = path
            }
        case "arxiv":
            kind = "id"
            rawLabel = queryValue("id_list") ?? path
        case "pubmed":
            kind = "pmid"
            rawLabel = queryValue("id") ?? path
        default:
            kind = "req"
            rawLabel = path
        }

        let sanitizedLabel = sanitizeSlugComponent(rawLabel, maxLength: 48)
        let hashPrefix = String(sha256Hex(of: Data(canonicalURL.utf8)).prefix(10))
        return "\(service)_\(kind)_\(sanitizedLabel)_\(hashPrefix)"
    }

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeSlugComponent(_ input: String, maxLength: Int) -> String {
        var chars: [Character] = []
        chars.reserveCapacity(min(input.count, maxLength))
        var previousWasUnderscore = false

        for scalar in input.unicodeScalars {
            let isASCIIAlphaNum =
                (scalar.value >= 0x30 && scalar.value <= 0x39) ||
                (scalar.value >= 0x41 && scalar.value <= 0x5A) ||
                (scalar.value >= 0x61 && scalar.value <= 0x7A)
            let isSafePunct = scalar == "." || scalar == "-"

            if isASCIIAlphaNum || isSafePunct {
                if scalar == "." && chars.last == "." {
                    continue
                }
                chars.append(Character(scalar))
                previousWasUnderscore = false
            } else if !previousWasUnderscore && !chars.isEmpty {
                chars.append("_")
                previousWasUnderscore = true
            }
            if chars.count >= maxLength {
                break
            }
        }

        while let first = chars.first, first == "_" || first == "." || first == "-" {
            chars.removeFirst()
        }
        while let last = chars.last, last == "_" || last == "." || last == "-" {
            chars.removeLast()
        }
        return chars.isEmpty ? "item" : String(chars)
    }

    private static func uppercasePercentEscapes(in raw: String) -> String {
        guard raw.contains("%") else { return raw }
        let utf8 = Array(raw.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count)
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x25 && index + 2 < utf8.count {
                let h1 = utf8[index + 1]
                let h2 = utf8[index + 2]
                if Self.isHexDigit(h1) && Self.isHexDigit(h2) {
                    out.append(0x25)
                    out.append(Self.uppercaseASCIIHex(h1))
                    out.append(Self.uppercaseASCIIHex(h2))
                    index += 3
                    continue
                }
            }
            out.append(utf8[index])
            index += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x46) ||
        (byte >= 0x61 && byte <= 0x66)
    }

    private static func uppercaseASCIIHex(_ byte: UInt8) -> UInt8 {
        (byte >= 0x61 && byte <= 0x66) ? (byte - 32) : byte
    }
}

// MARK: - Registry Recording Session

public actor RegistryRecordingSession: CitationRegistrySession {
    public nonisolated let directoryURL: URL
    public nonisolated let maxRequests: Int
    public nonisolated let minimumIntervalSeconds: TimeInterval
    public nonisolated let userAgent: String

    private let transport: any CitationRegistrySession
    private let startedAt: String
    private var orderedItems: [RegistryRecordedItem]
    private var itemsByURL: [String: RegistryRecordedItem]
    private var urlBySlug: [String: String]
    private var metaFilesSHA256: [String: String]
    private var httpRequestsSent: Int
    private var lastRequestFinishedUptime: TimeInterval?
    private var rateLimitAbortError: RegistryRecordingError?
    private var fatalError: RegistryRecordingError?

    // Serial execution gate ensuring at most 1 HTTP request is ever in flight.
    private var isExecutingRequest: Bool = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        directoryURL: URL,
        transport: any CitationRegistrySession = LiveURLSessionRegistryClient(
            capturedHeaderNames: LiveURLSessionRegistryClient.recordingCapturedHeaderNames
        ),
        maxRequests: Int = 80,
        minimumIntervalSeconds: TimeInterval = 0.35,
        userAgent: String = LiveURLSessionRegistryClient.defaultUserAgent
    ) throws {
        guard maxRequests > 0 else {
            throw RegistryRecordingError.ioFailure("maxRequests must be positive.")
        }
        try RegistryCanonicalURL.validateRequestHeaders(
            ["User-Agent": userAgent],
            expectedUserAgent: userAgent
        )

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: directoryURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw RegistryRecordingError.ioFailure("Target recording path is a regular file: \(directoryURL.path)")
            }
        } else {
            do {
                try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                throw RegistryRecordingError.ioFailure("Could not create recording directory: \(error.localizedDescription)")
            }
        }

        let nowISO = Self.iso8601UTCString()
        var loadedItems: [RegistryRecordedItem] = []
        var loadedByURL: [String: RegistryRecordedItem] = [:]
        var loadedBySlug: [String: String] = [:]
        var loadedMetaHashes: [String: String] = [:]
        var initialStartedAt = nowISO
        var initialRequestCount = 0

        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifestURL.path) {
            let validated = try RegistryReplayValidator.loadAndVerifyDirectory(directoryURL: directoryURL)
            initialStartedAt = validated.manifest.startedAt
            initialRequestCount = validated.manifest.totalHTTPRequestsSent
            for entry in validated.orderedEntries {
                loadedItems.append(entry.item)
                loadedByURL[entry.item.url] = entry.item
                loadedBySlug[entry.item.slug] = entry.item.url
                loadedMetaHashes["\(entry.item.slug).meta.json"] = entry.metaSHA256
            }
        }

        self.directoryURL = directoryURL
        self.transport = transport
        self.maxRequests = maxRequests
        self.minimumIntervalSeconds = max(0, minimumIntervalSeconds)
        self.userAgent = userAgent
        self.startedAt = initialStartedAt
        self.orderedItems = loadedItems
        self.itemsByURL = loadedByURL
        self.urlBySlug = loadedBySlug
        self.metaFilesSHA256 = loadedMetaHashes
        self.httpRequestsSent = initialRequestCount
    }

    public func throwIfFailed() throws {
        if let fatalError {
            throw fatalError
        }
    }

    public func send(_ request: URLRequest) async throws -> RegistryHTTPResponse {
        await acquireSerialSlot()
        defer { releaseSerialSlot() }

        let method = (request.httpMethod ?? "GET").uppercased()
        guard method == "GET" else {
            let err = RegistryRecordingError.unsupportedHTTPMethod(method)
            fatalError = err
            throw err
        }

        guard let rawURL = request.url else {
            let err = RegistryRecordingError.invalidRequestURL("<nil>")
            fatalError = err
            throw err
        }

        let canonicalURL: String
        let service: String
        do {
            (canonicalURL, service) = try RegistryCanonicalURL.normalizeForRecording(rawURL)
        } catch let recErr as RegistryRecordingError {
            fatalError = recErr
            throw recErr
        }

        var outgoingRequest = request
        outgoingRequest.url = URL(string: canonicalURL) ?? rawURL
        outgoingRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        var capturedReqHeaders = outgoingRequest.allHTTPHeaderFields ?? [:]
        capturedReqHeaders["User-Agent"] = userAgent

        do {
            try RegistryCanonicalURL.validateRequestHeaders(
                capturedReqHeaders,
                expectedUserAgent: userAgent
            )
        } catch let recErr as RegistryRecordingError {
            fatalError = recErr
            throw recErr
        }

        if let rateLimitAbortError {
            fatalError = rateLimitAbortError
            throw rateLimitAbortError
        }

        // Reuse already-recorded response for the exact same canonical URL (verifying SHA-256 on disk).
        if let existing = itemsByURL[canonicalURL] {
            let rawPath = directoryURL.appendingPathComponent(existing.rawFile)
            let data: Data
            do {
                data = try Data(contentsOf: rawPath)
            } catch {
                let err = RegistryRecordingError.corruptExistingDirectory("Missing raw file \(existing.rawFile)")
                fatalError = err
                throw err
            }
            let actualHash = RegistryCanonicalURL.sha256Hex(of: data)
            guard actualHash == existing.sha256.lowercased(), data.count == existing.byteLength else {
                let err = RegistryRecordingError.corruptExistingDirectory("SHA-256 mismatch in \(existing.rawFile)")
                fatalError = err
                throw err
            }
            return RegistryHTTPResponse(
                statusCode: existing.status,
                body: data,
                headers: existing.responseHeaders,
                origin: .network,
                fetchedAt: existing.requestedAt
            )
        }

        if httpRequestsSent >= maxRequests {
            let err = RegistryRecordingError.requestBudgetExceeded(limit: maxRequests, url: canonicalURL)
            fatalError = err
            throw err
        }

        let slug = try RegistryCanonicalURL.computeSlug(forNormalizedURL: canonicalURL)
        if let collidedURL = urlBySlug[slug], collidedURL != canonicalURL {
            let err = RegistryRecordingError.slugCollision(
                slug: slug,
                existingURL: collidedURL,
                newURL: canonicalURL
            )
            fatalError = err
            throw err
        }

        if minimumIntervalSeconds > 0, let lastUptime = lastRequestFinishedUptime {
            let elapsed = ProcessInfo.processInfo.systemUptime - lastUptime
            let remaining = minimumIntervalSeconds - elapsed
            if remaining > 0 {
                let nanos = UInt64((remaining * 1_000_000_000).rounded(.up))
                try await Task.sleep(nanoseconds: nanos)
            }
        }

        let requestedAt = Self.iso8601UTCString()
        httpRequestsSent += 1

        let response: RegistryHTTPResponse
        do {
            response = try await transport.send(outgoingRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastRequestFinishedUptime = ProcessInfo.processInfo.systemUptime
            let err = RegistryRecordingError.transportFailed(
                url: canonicalURL,
                detail: error.localizedDescription
            )
            fatalError = err
            throw err
        }
        lastRequestFinishedUptime = ProcessInfo.processInfo.systemUptime

        if response.statusCode == 429 {
            let err = RegistryRecordingError.rateLimited(
                url: canonicalURL,
                retryAfter: response.headerValue(for: "Retry-After")
            )
            rateLimitAbortError = err
            fatalError = err
            throw err
        }

        if response.statusCode >= 500 {
            let err = RegistryRecordingError.unexpectedServerStatus(
                statusCode: response.statusCode,
                url: canonicalURL
            )
            fatalError = err
            throw err
        }

        let rawFile = "\(slug).raw"
        let metaFile = "\(slug).meta.json"
        let sha256 = RegistryCanonicalURL.sha256Hex(of: response.body)
        let contentType = response.headerValue(for: "Content-Type") ?? ""
        let dateHeader = response.headerValue(for: "Date") ?? ""

        let item = RegistryRecordedItem(
            slug: slug,
            service: service,
            url: canonicalURL,
            status: response.statusCode,
            contentType: contentType,
            requestedAt: requestedAt,
            responseDateHeader: dateHeader,
            requestHeaders: capturedReqHeaders,
            responseHeaders: response.headers,
            rawFile: rawFile,
            byteLength: response.body.count,
            sha256: sha256,
            attempts: 1
        )

        do {
            // Save raw response bytes verbatim — zero byte modifications.
            try response.body.write(
                to: directoryURL.appendingPathComponent(rawFile),
                options: .atomic
            )
            let metaData = try Self.encodePrettyJSON(item)
            try metaData.write(
                to: directoryURL.appendingPathComponent(metaFile),
                options: .atomic
            )
            let metaHash = RegistryCanonicalURL.sha256Hex(of: metaData)

            orderedItems.append(item)
            itemsByURL[canonicalURL] = item
            urlBySlug[slug] = canonicalURL
            metaFilesSHA256[metaFile] = metaHash

            _ = try writeManifestToDisk()
        } catch let recErr as RegistryRecordingError {
            fatalError = recErr
            throw recErr
        } catch {
            let err = RegistryRecordingError.ioFailure(error.localizedDescription)
            fatalError = err
            throw err
        }

        return RegistryHTTPResponse(
            statusCode: response.statusCode,
            body: response.body,
            headers: response.headers,
            origin: .network,
            fetchedAt: requestedAt
        )
    }

    @discardableResult
    public func finalize() throws -> RegistryRecordingManifest {
        if let fatalError {
            throw fatalError
        }
        return try writeManifestToDisk()
    }

    private func writeManifestToDisk() throws -> RegistryRecordingManifest {
        let manifest = RegistryRecordingManifest(
            startedAt: startedAt,
            completedAt: Self.iso8601UTCString(),
            userAgent: userAgent,
            count: orderedItems.count,
            totalHTTPRequestsSent: httpRequestsSent,
            items: orderedItems,
            metaFilesSHA256: metaFilesSHA256
        )
        do {
            let data = try Self.encodePrettyJSON(manifest)
            try data.write(
                to: directoryURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            return manifest
        } catch {
            throw RegistryRecordingError.ioFailure("Failed writing manifest.json: \(error.localizedDescription)")
        }
    }

    private func acquireSerialSlot() async {
        if !isExecutingRequest {
            isExecutingRequest = true
            return
        }
        await withCheckedContinuation { continuation in
            sendWaiters.append(continuation)
        }
    }

    private func releaseSerialSlot() {
        if sendWaiters.isEmpty {
            isExecutingRequest = false
        } else {
            let next = sendWaiters.removeFirst()
            next.resume()
        }
    }

    private static func encodePrettyJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        if data.last != 0x0A {
            data.append(0x0A)
        }
        return data
    }

    private static func iso8601UTCString(from date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - Registry Replay Session & Directory Integrity Validator

enum RegistryReplayValidator {
    struct VerifiedEntry: Sendable {
        let item: RegistryRecordedItem
        let body: Data
        let metaSHA256: String
    }

    struct VerifiedDirectory: Sendable {
        let manifest: RegistryRecordingManifest
        let orderedEntries: [VerifiedEntry]
        let entriesByURL: [String: VerifiedEntry]
    }

    static func loadAndVerifyDirectory(directoryURL: URL) throws -> VerifiedDirectory {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw RegistryReplayError.missingDirectory(directoryURL.path)
        }

        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw RegistryReplayError.missingManifest(manifestURL.path)
        }

        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw RegistryReplayError.corruptManifest("Unreadable manifest.json: \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        let manifest: RegistryRecordingManifest
        do {
            manifest = try decoder.decode(RegistryRecordingManifest.self, from: manifestData)
        } catch {
            throw RegistryReplayError.corruptManifest("Malformed JSON in manifest.json: \(error.localizedDescription)")
        }

        guard manifest.count == manifest.items.count else {
            throw RegistryReplayError.corruptManifest(
                "manifest count (\(manifest.count)) does not match items length (\(manifest.items.count))."
            )
        }

        if let metaMap = manifest.metaFilesSHA256, metaMap.count != manifest.items.count {
            throw RegistryReplayError.corruptManifest(
                "manifest meta_files_sha256 count (\(metaMap.count)) does not match items length (\(manifest.items.count))."
            )
        }

        var ordered: [VerifiedEntry] = []
        ordered.reserveCapacity(manifest.items.count)
        var byURL: [String: VerifiedEntry] = [:]
        var seenSlugs: Set<String> = []

        for item in manifest.items {
            guard Self.isSafeSingleFilenameComponent(item.slug),
                  item.rawFile == "\(item.slug).raw" else {
                throw RegistryReplayError.corruptManifest("Unsafe slug or raw_file in manifest for '\(item.slug)'.")
            }
            guard seenSlugs.insert(item.slug).inserted else {
                throw RegistryReplayError.corruptManifest("Duplicate slug '\(item.slug)' in manifest.json.")
            }

            guard let parsedURL = URL(string: item.url) else {
                throw RegistryReplayError.corruptManifest("Invalid URL '\(item.url)' in manifest.json.")
            }
            let normalizedURL = try RegistryCanonicalURL.normalizeForReplay(parsedURL)
            guard normalizedURL == item.url else {
                throw RegistryReplayError.corruptManifest(
                    "Non-canonical URL in manifest.json: '\(item.url)' vs '\(normalizedURL)'."
                )
            }
            guard byURL[normalizedURL] == nil else {
                throw RegistryReplayError.corruptManifest("Duplicate URL '\(normalizedURL)' in manifest.json.")
            }

            // 1. Validate <slug>.raw presence, byte length, and SHA-256
            let rawURL = directoryURL.appendingPathComponent(item.rawFile)
            guard fm.fileExists(atPath: rawURL.path) else {
                throw RegistryReplayError.missingRawFile(file: item.rawFile, url: item.url)
            }
            let rawData: Data
            do {
                rawData = try Data(contentsOf: rawURL)
            } catch {
                throw RegistryReplayError.missingRawFile(file: item.rawFile, url: item.url)
            }
            guard rawData.count == item.byteLength else {
                throw RegistryReplayError.byteLengthMismatch(
                    file: item.rawFile,
                    expected: item.byteLength,
                    actual: rawData.count
                )
            }
            let actualRawHash = RegistryCanonicalURL.sha256Hex(of: rawData)
            guard actualRawHash == item.sha256.lowercased() else {
                throw RegistryReplayError.checksumMismatch(
                    file: item.rawFile,
                    expected: item.sha256.lowercased(),
                    actual: actualRawHash
                )
            }

            // 2. Validate <slug>.meta.json presence, optional manifest SHA-256 pin, and field equality
            let metaFileName = "\(item.slug).meta.json"
            let metaURL = directoryURL.appendingPathComponent(metaFileName)
            guard fm.fileExists(atPath: metaURL.path) else {
                throw RegistryReplayError.missingMetaFile(file: metaFileName, url: item.url)
            }
            let metaData: Data
            do {
                metaData = try Data(contentsOf: metaURL)
            } catch {
                throw RegistryReplayError.missingMetaFile(file: metaFileName, url: item.url)
            }
            let actualMetaHash = RegistryCanonicalURL.sha256Hex(of: metaData)
            if let expectedMetaHash = manifest.metaFilesSHA256?[metaFileName] {
                guard actualMetaHash == expectedMetaHash.lowercased() else {
                    throw RegistryReplayError.checksumMismatch(
                        file: metaFileName,
                        expected: expectedMetaHash.lowercased(),
                        actual: actualMetaHash
                    )
                }
            }

            let metaItem: RegistryRecordedItem
            do {
                metaItem = try decoder.decode(RegistryRecordedItem.self, from: metaData)
            } catch {
                throw RegistryReplayError.corruptMetaFile(
                    file: metaFileName,
                    detail: error.localizedDescription
                )
            }
            guard metaItem == item else {
                throw RegistryReplayError.corruptMetaFile(
                    file: metaFileName,
                    detail: "Metadata fields differ from manifest.json entry for '\(item.slug)'."
                )
            }

            let verified = VerifiedEntry(item: item, body: rawData, metaSHA256: actualMetaHash)
            ordered.append(verified)
            byURL[normalizedURL] = verified
        }

        // 3. Reject orphan .raw or .meta.json files in the directory whose SHA-256 is not tracked by manifest.json
        let contents = (try? fm.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        for fileName in contents {
            if fileName == "manifest.json" || fileName.hasPrefix(".") {
                continue
            }
            if fileName.hasSuffix(".raw") {
                let slug = String(fileName.dropLast(".raw".count))
                if !seenSlugs.contains(slug) {
                    throw RegistryReplayError.corruptManifest("Untracked raw fixture file '\(fileName)' not listed in manifest.json.")
                }
            } else if fileName.hasSuffix(".meta.json") {
                let slug = String(fileName.dropLast(".meta.json".count))
                if !seenSlugs.contains(slug) {
                    throw RegistryReplayError.corruptManifest("Untracked meta fixture file '\(fileName)' not listed in manifest.json.")
                }
            }
        }

        return VerifiedDirectory(
            manifest: manifest,
            orderedEntries: ordered,
            entriesByURL: byURL
        )
    }

    private static func isSafeSingleFilenameComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("..") else {
            return false
        }
        return true
    }
}

public actor RegistryReplaySession: CitationRegistrySession {
    public nonisolated let directoryURL: URL
    public nonisolated let bypassesCache: Bool = true
    public nonisolated let manifest: RegistryRecordingManifest

    private let entriesByURL: [String: RegistryReplayValidator.VerifiedEntry]
    private var fatalError: RegistryReplayError?

    public init(directoryURL: URL) throws {
        let verified = try RegistryReplayValidator.loadAndVerifyDirectory(directoryURL: directoryURL)
        self.directoryURL = directoryURL
        self.manifest = verified.manifest
        self.entriesByURL = verified.entriesByURL
    }

    public func throwIfFailed() throws {
        if let fatalError {
            throw fatalError
        }
    }

    public func send(_ request: URLRequest) async throws -> RegistryHTTPResponse {
        guard let rawURL = request.url else {
            let err = RegistryReplayError.unrecordedRequest(url: "<nil>")
            if fatalError == nil {
                fatalError = err
            }
            throw err
        }

        let normalizedURL = (try? RegistryCanonicalURL.normalizeForReplay(rawURL)) ?? rawURL.absoluteString
        guard let entry = entriesByURL[normalizedURL] else {
            let err = RegistryReplayError.unrecordedRequest(url: normalizedURL)
            if fatalError == nil {
                fatalError = err
            }
            throw err
        }

        return RegistryHTTPResponse(
            statusCode: entry.item.status,
            body: entry.body,
            headers: entry.item.responseHeaders,
            origin: .replay,
            fetchedAt: entry.item.requestedAt
        )
    }
}
