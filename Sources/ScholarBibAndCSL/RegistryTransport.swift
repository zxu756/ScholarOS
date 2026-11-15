import Foundation

// MARK: - Registry Transport Errors, Responses & Injectable Sessions

public enum RegistryTransportErrorKind: String, Sendable, Codable, Hashable {
    case transportError = "transport_error"
    case timeout = "timeout"
}

public struct RegistryTransportError: Error, LocalizedError, Sendable, Hashable {
    public let kind: RegistryTransportErrorKind
    public let detail: String
    public let url: URL?

    public var reasonCode: String { kind.rawValue }

    public init(kind: RegistryTransportErrorKind, detail: String, url: URL? = nil) {
        self.kind = kind
        self.detail = detail
        self.url = url
    }

    public var errorDescription: String? {
        "[\(kind.rawValue)] \(detail)"
    }
}

public struct RegistryHTTPResponse: Sendable, Codable, Hashable {
    public let statusCode: Int
    public let body: Data
    public let headers: [String: String]

    public init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    /// Case-insensitive header lookup across captured response headers.
    public func headerValue(for name: String) -> String? {
        if let exact = headers[name] {
            return exact
        }
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }

    public static func json(
        statusCode: Int = 200,
        _ jsonString: String,
        headers: [String: String] = [:]
    ) -> RegistryHTTPResponse {
        var merged = ["Content-Type": "application/json"]
        for (key, value) in headers {
            merged[key] = value
        }
        return RegistryHTTPResponse(
            statusCode: statusCode,
            body: Data(jsonString.utf8),
            headers: merged
        )
    }

    public static func xml(
        statusCode: Int = 200,
        _ xmlString: String,
        headers: [String: String] = [:]
    ) -> RegistryHTTPResponse {
        var merged = ["Content-Type": "application/atom+xml"]
        for (key, value) in headers {
            merged[key] = value
        }
        return RegistryHTTPResponse(
            statusCode: statusCode,
            body: Data(xmlString.utf8),
            headers: merged
        )
    }
}

public protocol CitationRegistrySession: Sendable {
    func send(_ request: URLRequest) async throws -> RegistryHTTPResponse
}

/// Closure-backed `CitationRegistrySession` for lightweight injection in tests and pipelines.
public struct ClosureRegistrySession: CitationRegistrySession, Sendable {
    public typealias Handler = @Sendable (URLRequest) async throws -> RegistryHTTPResponse

    private let handler: Handler

    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    public func send(_ request: URLRequest) async throws -> RegistryHTTPResponse {
        try await handler(request)
    }
}

/// Ephemeral, cache-disabled HTTP transport client for public bibliographic registries.
public struct LiveURLSessionRegistryClient: CitationRegistrySession, Sendable {
    public typealias RawDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let currentVersion: String = "1.2.0"
    public static let defaultUserAgent: String = "ScholarOS/\(currentVersion)"
    public static let defaultTimeoutInterval: TimeInterval = 15.0

    public static let defaultCapturedHeaderNames: [String] = [
        "Content-Type",
        "Retry-After",
        "x-rate-limit-limit",
        "x-rate-limit-interval",
        "x-concurrency-limit",
        "x-ratelimit-remaining",
        "x-ratelimit-cost-usd"
    ]

    private static let sharedEphemeralSession: URLSession = URLSession(
        configuration: makeEphemeralConfiguration(timeoutInterval: defaultTimeoutInterval)
    )

    public let timeoutInterval: TimeInterval
    public let capturedHeaderNames: [String]

    private let session: URLSession?
    private let dataLoader: RawDataLoader

    public var sessionConfiguration: URLSessionConfiguration? {
        session?.configuration
    }

    public static func makeEphemeralConfiguration(
        timeoutInterval: TimeInterval = defaultTimeoutInterval,
        protocolClasses: [AnyClass]? = nil
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = timeoutInterval
        config.timeoutIntervalForResource = timeoutInterval
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        return config
    }

    public init(
        timeoutInterval: TimeInterval = LiveURLSessionRegistryClient.defaultTimeoutInterval,
        capturedHeaderNames: [String] = LiveURLSessionRegistryClient.defaultCapturedHeaderNames,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.timeoutInterval = timeoutInterval
        self.capturedHeaderNames = capturedHeaderNames

        let resolvedSession: URLSession
        if timeoutInterval == Self.defaultTimeoutInterval && protocolClasses == nil {
            resolvedSession = Self.sharedEphemeralSession
        } else {
            let config = Self.makeEphemeralConfiguration(
                timeoutInterval: timeoutInterval,
                protocolClasses: protocolClasses
            )
            resolvedSession = URLSession(configuration: config)
        }
        self.session = resolvedSession
        self.dataLoader = { request in
            try await resolvedSession.data(for: request)
        }
    }

    public init(
        timeoutInterval: TimeInterval = LiveURLSessionRegistryClient.defaultTimeoutInterval,
        capturedHeaderNames: [String] = LiveURLSessionRegistryClient.defaultCapturedHeaderNames,
        dataLoader: @escaping RawDataLoader
    ) {
        self.timeoutInterval = timeoutInterval
        self.capturedHeaderNames = capturedHeaderNames
        self.session = nil
        self.dataLoader = dataLoader
    }

    public func send(_ request: URLRequest) async throws -> RegistryHTTPResponse {
        var configured = request
        configured.timeoutInterval = timeoutInterval
        configured.cachePolicy = .reloadIgnoringLocalCacheData
        configured.httpShouldHandleCookies = false
        configured.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataLoader(configured)
        } catch let transportError as RegistryTransportError {
            throw transportError
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw RegistryTransportError(
                kind: .timeout,
                detail: "Registry request timed out after \(timeoutInterval)s: \(urlError.localizedDescription)",
                url: configured.url
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                throw RegistryTransportError(
                    kind: .timeout,
                    detail: "Registry request timed out after \(timeoutInterval)s: \(error.localizedDescription)",
                    url: configured.url
                )
            }
            throw RegistryTransportError(
                kind: .transportError,
                detail: "Registry transport failed: \(error.localizedDescription)",
                url: configured.url
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RegistryTransportError(
                kind: .transportError,
                detail: "Expected HTTPURLResponse but received \(type(of: response)).",
                url: configured.url
            )
        }

        let headers = Self.extractHeaders(
            from: httpResponse,
            capturedHeaderNames: capturedHeaderNames
        )
        return RegistryHTTPResponse(
            statusCode: httpResponse.statusCode,
            body: data,
            headers: headers
        )
    }

    private static func extractHeaders(
        from response: HTTPURLResponse,
        capturedHeaderNames: [String]
    ) -> [String: String] {
        var canonicalByLowercase: [String: String] = [:]
        canonicalByLowercase.reserveCapacity(capturedHeaderNames.count)
        for name in capturedHeaderNames {
            canonicalByLowercase[name.lowercased()] = name
        }

        var extracted: [String: String] = [:]
        for (rawKey, rawValue) in response.allHeaderFields {
            let lowerKey = String(describing: rawKey).lowercased()
            guard let canonicalName = canonicalByLowercase[lowerKey] else {
                continue
            }
            let value = String(describing: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            extracted[canonicalName] = value
        }
        return extracted
    }
}

// MARK: - URLComponents Endpoint Builder for Public Scholarly Registries

public enum RegistryURLBuilder: Sendable {

    private static let doiResolverPrefixes: [String] = [
        "https://doi.org/",
        "http://doi.org/",
        "https://dx.doi.org/",
        "http://dx.doi.org/",
        "https://www.doi.org/",
        "doi.org/",
        "dx.doi.org/",
        "doi:"
    ]

    /// Builds `https://api.crossref.org/works/<DOI>` via `URLComponents`, percent-encoding `#`, `?`, spaces, and angle brackets in the path.
    public static func crossrefWorkURL(doi: String) -> URL? {
        guard let cleanDOI = prepareDOIForPath(doi) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.crossref.org"
        components.path = "/works/\(cleanDOI)"
        return components.url
    }

    /// Builds `https://api.crossref.org/works?query.bibliographic=<query>&rows=<rows>` via `URLComponents`.
    public static func crossrefBibliographicSearchURL(query: String, rows: Int = 5) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rows > 0 else { return nil }
        return buildQueryURL(
            host: "api.crossref.org",
            path: "/works",
            queryItems: [
                URLQueryItem(name: "query.bibliographic", value: trimmed),
                URLQueryItem(name: "rows", value: String(rows))
            ]
        )
    }

    /// Builds `https://api.openalex.org/works/https://doi.org/<DOI>` via `URLComponents`, percent-encoding `#`, `?`, spaces, and angle brackets in the path.
    public static func openAlexWorkURL(doi: String) -> URL? {
        guard let cleanDOI = prepareDOIForPath(doi) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.openalex.org"
        components.path = "/works/https://doi.org/\(cleanDOI)"
        return components.url
    }

    /// Builds `https://api.openalex.org/works?search=<query>&per-page=<perPage>` via `URLComponents`.
    public static func openAlexSearchURL(query: String, perPage: Int = 5) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, perPage > 0 else { return nil }
        return buildQueryURL(
            host: "api.openalex.org",
            path: "/works",
            queryItems: [
                URLQueryItem(name: "search", value: trimmed),
                URLQueryItem(name: "per-page", value: String(perPage))
            ]
        )
    }

    /// Builds `https://doi.org/api/handles/<DOI>` via `URLComponents`, percent-encoding `#`, `?`, spaces, and angle brackets in the path.
    public static func doiHandleURL(doi: String) -> URL? {
        guard let cleanDOI = prepareDOIForPath(doi) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "doi.org"
        components.path = "/api/handles/\(cleanDOI)"
        return components.url
    }

    /// Builds `https://export.arxiv.org/api/query?id_list=<arXivID>` via `URLComponents`.
    public static func arXivQueryURL(arXivID: String) -> URL? {
        let trimmed = arXivID.trimmingCharacters(in: .newlines)
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return buildQueryURL(
            host: "export.arxiv.org",
            path: "/api/query",
            queryItems: [
                URLQueryItem(name: "id_list", value: trimmed)
            ]
        )
    }

    /// Builds `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=<pmid>&retmode=json` via `URLComponents`.
    public static func pubMedSummaryURL(pmid: String) -> URL? {
        let trimmed = pmid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return buildQueryURL(
            host: "eutils.ncbi.nlm.nih.gov",
            path: "/entrez/eutils/esummary.fcgi",
            queryItems: [
                URLQueryItem(name: "db", value: "pubmed"),
                URLQueryItem(name: "id", value: trimmed),
                URLQueryItem(name: "retmode", value: "json")
            ]
        )
    }

    private static func prepareDOIForPath(_ rawDOI: String) -> String? {
        var candidate = rawDOI.trimmingCharacters(in: CharacterSet.newlines.union(CharacterSet(charactersIn: "\t")))
        while candidate.first == " " {
            candidate.removeFirst()
        }
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let lower = candidate.lowercased()
        for prefix in doiResolverPrefixes {
            if lower.hasPrefix(prefix) {
                candidate = String(candidate.dropFirst(prefix.count))
                while candidate.first == " " {
                    candidate.removeFirst()
                }
                break
            }
        }

        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return candidate
    }

    private static let rfc3986UnreservedQueryCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func buildQueryURL(
        host: String,
        path: String,
        queryItems: [URLQueryItem]
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        var encodedItems: [URLQueryItem] = []
        encodedItems.reserveCapacity(queryItems.count)
        for item in queryItems {
            guard let encodedName = item.name.addingPercentEncoding(withAllowedCharacters: rfc3986UnreservedQueryCharacters) else {
                return nil
            }
            let encodedValue: String?
            if let value = item.value {
                guard let v = value.addingPercentEncoding(withAllowedCharacters: rfc3986UnreservedQueryCharacters) else {
                    return nil
                }
                encodedValue = v
            } else {
                encodedValue = nil
            }
            encodedItems.append(URLQueryItem(name: encodedName, value: encodedValue))
        }
        components.percentEncodedQueryItems = encodedItems
        return components.url
    }
}
