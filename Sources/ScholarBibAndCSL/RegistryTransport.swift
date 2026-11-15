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

public enum CitationVerdictSourceOrigin: String, Sendable, Codable, Hashable, CaseIterable {
    case network = "network"
    case cache = "cache"
    case replay = "replay"
}

public struct RegistryHTTPResponse: Sendable, Codable, Hashable {
    public let statusCode: Int
    public let body: Data
    public let headers: [String: String]
    public let origin: CitationVerdictSourceOrigin
    public let fetchedAt: String?

    public init(
        statusCode: Int,
        body: Data,
        headers: [String: String] = [:],
        origin: CitationVerdictSourceOrigin = .network,
        fetchedAt: String? = nil
    ) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
        self.origin = origin
        self.fetchedAt = fetchedAt
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

// MARK: - Injectable Clock, Telemetry & Unified Registry Rate Limiter / Retry Coordinator (M1 Item 6 & 8)

public protocol RegistryClock: Sendable {
    func now() -> TimeInterval
    func currentDate() -> Date
    func sleep(_ seconds: TimeInterval) async throws
}

extension RegistryClock {
    public func currentDate() -> Date {
        Date()
    }
}

public struct SystemRegistryClock: RegistryClock, Sendable {
    public init() {}

    public func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func currentDate() -> Date {
        Date()
    }

    public func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let nanos = UInt64((seconds * 1_000_000_000).rounded(.up))
        try await Task.sleep(nanoseconds: nanos)
    }
}

public struct ClosureRegistryClock: RegistryClock, Sendable {
    /// Default anchor timestamp (`2026-11-16T00:00:00Z`) when no explicit `currentDate` closure is provided.
    public static let defaultVirtualEpoch: TimeInterval = 1_794_787_200

    private let nowHandler: @Sendable () -> TimeInterval
    private let dateHandler: @Sendable () -> Date
    private let sleepHandler: @Sendable (TimeInterval) async throws -> Void

    public init(
        now: @escaping @Sendable () -> TimeInterval,
        currentDate: (@Sendable () -> Date)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.nowHandler = now
        self.dateHandler = currentDate ?? { Date(timeIntervalSince1970: Self.defaultVirtualEpoch + now()) }
        self.sleepHandler = sleep
    }

    public func now() -> TimeInterval {
        nowHandler()
    }

    public func currentDate() -> Date {
        dateHandler()
    }

    public func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await sleepHandler(seconds)
    }
}

private final class InstantVirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0.0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if seconds > 0 {
            current += seconds
        }
    }
}

extension RegistryClock where Self == ClosureRegistryClock {
    /// Non-sleeping virtual clock advancing instantaneously on `sleep(_:)`, for replay and unit tests.
    public static var immediate: ClosureRegistryClock {
        let state = InstantVirtualClock()
        return ClosureRegistryClock(
            now: { state.now() },
            sleep: { state.advance($0) }
        )
    }
}

public struct RegistryBudgetExhaustedError: Error, LocalizedError, Sendable, Equatable {
    public let remainingCredits: Double?
    public let url: URL?

    public var reasonCode: String { "budget_exhausted" }

    public init(remainingCredits: Double?, url: URL? = nil) {
        self.remainingCredits = remainingCredits
        self.url = url
    }

    public var errorDescription: String? {
        if let remainingCredits {
            return "OpenAlex search skipped because x-ratelimit-remaining (\(remainingCredits)) is below 10."
        }
        return "OpenAlex search skipped because x-ratelimit-remaining is below 10."
    }
}

public struct RegistryRequestTelemetryEvent: Sendable, Equatable {
    public let source: String
    public let url: String
    public let statusCode: Int?
    public let errorDescription: String?
    public let elapsedSeconds: TimeInterval
    public let origin: CitationVerdictSourceOrigin
    public let startedAtUptime: TimeInterval
    public let completedAtUptime: TimeInterval

    public init(
        source: String,
        url: String,
        statusCode: Int?,
        errorDescription: String? = nil,
        elapsedSeconds: TimeInterval,
        origin: CitationVerdictSourceOrigin,
        startedAtUptime: TimeInterval = 0,
        completedAtUptime: TimeInterval = 0
    ) {
        self.source = source
        self.url = url
        self.statusCode = statusCode
        self.errorDescription = errorDescription
        self.elapsedSeconds = elapsedSeconds
        self.origin = origin
        self.startedAtUptime = startedAtUptime
        self.completedAtUptime = completedAtUptime
    }
}

public typealias RegistryRequestObserver = @Sendable (RegistryRequestTelemetryEvent) -> Void

/// Unified per-host rate limiter, retry coordinator, and OpenAlex search budget guard (M1 item 6).
/// - Crossref (`api.crossref.org`): at most 1 request in flight; spacing governed by
///   `x-rate-limit-limit` / `x-rate-limit-interval` headers, defaulting to 5 req/s (0.2s) for single-work
///   lookups and 1 req/s (1.0s) for search requests when headers are absent.
/// - arXiv (`export.arxiv.org`): at least 3.0s between requests.
/// - PubMed (`eutils.ncbi.nlm.nih.gov`): at most 3 req/s (1/3 s between requests).
/// - HTTP 429 and 503: honors `Retry-After` (capped at 60s) or exponential backoff (1, 2, 4s), up to 3 retries.
/// - Other HTTP 5xx: retries 1 time.
/// - OpenAlex (`api.openalex.org`): once any response reports `x-ratelimit-remaining < 10`, blocks all
///   subsequent OpenAlex search requests in this limiter's run with `RegistryBudgetExhaustedError`.
public actor RegistryRateLimiter {
    public static let shared = RegistryRateLimiter()

    public static let defaultCrossrefSingleIntervalSeconds: TimeInterval = 0.2
    public static let defaultCrossrefSearchIntervalSeconds: TimeInterval = 1.0
    public static let defaultArXivIntervalSeconds: TimeInterval = 3.0
    public static let defaultPubMedIntervalSeconds: TimeInterval = 1.0 / 3.0
    public static let maxRetryAfterSeconds: TimeInterval = 60.0
    public static let exponentialBackoffSeconds: [TimeInterval] = [1.0, 2.0, 4.0]
    public static let openAlexMinimumSearchCredits: Double = 10.0

    private let clock: any RegistryClock

    // Crossref single-in-flight gate & dynamic intervals
    private var isCrossrefGateHeld: Bool = false
    private var crossrefWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentCrossrefInFlight: Int = 0
    public private(set) var maxObservedCrossrefInFlight: Int = 0
    private var crossrefSingleIntervalSeconds: TimeInterval = RegistryRateLimiter.defaultCrossrefSingleIntervalSeconds
    private var crossrefSearchIntervalSeconds: TimeInterval = RegistryRateLimiter.defaultCrossrefSearchIntervalSeconds
    private var lastCrossrefAnyTimestamp: TimeInterval?
    private var lastCrossrefSearchTimestamp: TimeInterval?

    // arXiv serial gate & 3s spacing
    private var isArXivGateHeld: Bool = false
    private var arXivWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastArXivTimestamp: TimeInterval?

    // PubMed serial gate & 3/s spacing
    private var isPubMedGateHeld: Bool = false
    private var pubMedWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastPubMedTimestamp: TimeInterval?

    // OpenAlex search budget state
    public private(set) var openAlexSearchBudgetExhausted: Bool = false
    public private(set) var lastOpenAlexRemainingCredits: Double?

    public init(clock: any RegistryClock = SystemRegistryClock()) {
        self.clock = clock
    }

    public func send(
        _ request: URLRequest,
        source: String,
        using session: any CitationRegistrySession,
        observer: RegistryRequestObserver? = nil
    ) async throws -> RegistryHTTPResponse {
        let host = request.url?.host?.lowercased() ?? ""

        if Self.isOpenAlexSearchRequest(request, host: host), openAlexSearchBudgetExhausted {
            throw RegistryBudgetExhaustedError(
                remainingCredits: lastOpenAlexRemainingCredits,
                url: request.url
            )
        }

        switch host {
        case "api.crossref.org":
            await acquireCrossrefGate()
            defer { releaseCrossrefGate() }
            return try await executeWithRetries(
                request: request,
                host: host,
                source: source,
                using: session,
                observer: observer
            )
        case "export.arxiv.org":
            await acquireArXivGate()
            defer { releaseArXivGate() }
            return try await executeWithRetries(
                request: request,
                host: host,
                source: source,
                using: session,
                observer: observer
            )
        case "eutils.ncbi.nlm.nih.gov":
            await acquirePubMedGate()
            defer { releasePubMedGate() }
            return try await executeWithRetries(
                request: request,
                host: host,
                source: source,
                using: session,
                observer: observer
            )
        default:
            return try await executeWithRetries(
                request: request,
                host: host,
                source: source,
                using: session,
                observer: observer
            )
        }
    }

    private func executeWithRetries(
        request: URLRequest,
        host: String,
        source: String,
        using session: any CitationRegistrySession,
        observer: RegistryRequestObserver?
    ) async throws -> RegistryHTTPResponse {
        var attemptIndex = 0

        while true {
            if Self.isOpenAlexSearchRequest(request, host: host), openAlexSearchBudgetExhausted {
                throw RegistryBudgetExhaustedError(
                    remainingCredits: lastOpenAlexRemainingCredits,
                    url: request.url
                )
            }

            if attemptIndex == 0 {
                try await waitHostSpacingBeforeInitialAttempt(request: request, host: host)
            }

            let isCrossref = (host == "api.crossref.org")
            let isCrossrefSearch = isCrossref && Self.isCrossrefSearchRequest(request)
            if isCrossref {
                currentCrossrefInFlight += 1
                if currentCrossrefInFlight > maxObservedCrossrefInFlight {
                    maxObservedCrossrefInFlight = currentCrossrefInFlight
                }
            }

            let clockStart = clock.now()
            let wallStart = ProcessInfo.processInfo.systemUptime
            recordHostStartTimestamp(host: host, isCrossrefSearch: isCrossrefSearch, timestamp: clockStart)

            let response: RegistryHTTPResponse
            do {
                response = try await session.send(request)
            } catch {
                let clockEnd = max(clockStart, clock.now())
                let wallEnd = max(wallStart, ProcessInfo.processInfo.systemUptime)
                let wallElapsed = wallEnd - wallStart
                if isCrossref {
                    currentCrossrefInFlight -= 1
                }
                recordHostCompletionTimestamp(host: host, isCrossrefSearch: isCrossrefSearch, timestamp: clockEnd)

                if !(error is CancellationError) && !(error is any FatalRegistrySessionError) {
                    let fallbackOrigin: CitationVerdictSourceOrigin = (session is RegistryReplaySession) ? .replay : .network
                    observer?(
                        RegistryRequestTelemetryEvent(
                            source: source,
                            url: request.url?.absoluteString ?? "<nil>",
                            statusCode: nil,
                            errorDescription: error.localizedDescription,
                            elapsedSeconds: wallElapsed,
                            origin: fallbackOrigin,
                            startedAtUptime: wallStart,
                            completedAtUptime: wallEnd
                        )
                    )
                }
                throw error
            }

            let clockEnd = max(clockStart, clock.now())
            let wallEnd = max(wallStart, ProcessInfo.processInfo.systemUptime)
            let wallElapsed = wallEnd - wallStart
            if isCrossref {
                currentCrossrefInFlight -= 1
            }
            recordHostCompletionTimestamp(host: host, isCrossrefSearch: isCrossrefSearch, timestamp: clockEnd)

            if isCrossref {
                updateCrossrefIntervals(from: response, isSearch: isCrossrefSearch)
            }
            if host == "api.openalex.org" {
                updateOpenAlexBudget(from: response)
            }

            observer?(
                RegistryRequestTelemetryEvent(
                    source: source,
                    url: request.url?.absoluteString ?? "<nil>",
                    statusCode: response.statusCode,
                    errorDescription: nil,
                    elapsedSeconds: wallElapsed,
                    origin: response.origin,
                    startedAtUptime: wallStart,
                    completedAtUptime: wallEnd
                )
            )

            // OpenAlex exhausted budget on a failed response -> stop immediately without retrying.
            if host == "api.openalex.org",
               let remaining = Self.parseOpenAlexRemainingHeader(from: response),
               remaining < Self.openAlexMinimumSearchCredits,
               response.statusCode != 200,
               response.statusCode != 404 {
                return response
            }

            let status = response.statusCode
            if status == 429 || status == 503 {
                if attemptIndex < 3 {
                    let waitSeconds = Self.retryWaitSeconds(for: response, attemptIndex: attemptIndex)
                    try await clock.sleep(waitSeconds)
                    let afterSleep = clock.now()
                    recordHostCompletionTimestamp(
                        host: host,
                        isCrossrefSearch: isCrossrefSearch,
                        timestamp: max(clockEnd, afterSleep)
                    )
                    attemptIndex += 1
                    continue
                }
                return response
            }

            if (500...599).contains(status) {
                if attemptIndex < 1 {
                    let waitSeconds = Self.parseRetryAfterSeconds(from: response) ?? 1.0
                    try await clock.sleep(waitSeconds)
                    let afterSleep = clock.now()
                    recordHostCompletionTimestamp(
                        host: host,
                        isCrossrefSearch: isCrossrefSearch,
                        timestamp: max(clockEnd, afterSleep)
                    )
                    attemptIndex += 1
                    continue
                }
                return response
            }

            return response
        }
    }

    private func waitHostSpacingBeforeInitialAttempt(request: URLRequest, host: String) async throws {
        let now = clock.now()
        switch host {
        case "api.crossref.org":
            let isSearch = Self.isCrossrefSearchRequest(request)
            var requiredSleep: TimeInterval = 0
            let poolInterval = isSearch ? crossrefSearchIntervalSeconds : crossrefSingleIntervalSeconds
            if let lastAny = lastCrossrefAnyTimestamp {
                requiredSleep = max(requiredSleep, poolInterval - (now - lastAny))
            }
            if isSearch, let lastSearch = lastCrossrefSearchTimestamp {
                requiredSleep = max(requiredSleep, crossrefSearchIntervalSeconds - (now - lastSearch))
            }
            if requiredSleep > 0 {
                try await clock.sleep(requiredSleep)
            }
        case "export.arxiv.org":
            if let last = lastArXivTimestamp {
                let remaining = Self.defaultArXivIntervalSeconds - (now - last)
                if remaining > 0 {
                    try await clock.sleep(remaining)
                }
            }
        case "eutils.ncbi.nlm.nih.gov":
            if let last = lastPubMedTimestamp {
                let remaining = Self.defaultPubMedIntervalSeconds - (now - last)
                if remaining > 0 {
                    try await clock.sleep(remaining)
                }
            }
        default:
            break
        }
    }

    private func recordHostStartTimestamp(host: String, isCrossrefSearch: Bool, timestamp: TimeInterval) {
        switch host {
        case "api.crossref.org":
            lastCrossrefAnyTimestamp = timestamp
            if isCrossrefSearch {
                lastCrossrefSearchTimestamp = timestamp
            }
        case "export.arxiv.org":
            lastArXivTimestamp = timestamp
        case "eutils.ncbi.nlm.nih.gov":
            lastPubMedTimestamp = timestamp
        default:
            break
        }
    }

    private func recordHostCompletionTimestamp(host: String, isCrossrefSearch: Bool, timestamp: TimeInterval) {
        switch host {
        case "api.crossref.org":
            if let prev = lastCrossrefAnyTimestamp {
                lastCrossrefAnyTimestamp = max(prev, timestamp)
            } else {
                lastCrossrefAnyTimestamp = timestamp
            }
            if isCrossrefSearch {
                if let prevSearch = lastCrossrefSearchTimestamp {
                    lastCrossrefSearchTimestamp = max(prevSearch, timestamp)
                } else {
                    lastCrossrefSearchTimestamp = timestamp
                }
            }
        case "export.arxiv.org":
            if let prev = lastArXivTimestamp {
                lastArXivTimestamp = max(prev, timestamp)
            } else {
                lastArXivTimestamp = timestamp
            }
        case "eutils.ncbi.nlm.nih.gov":
            if let prev = lastPubMedTimestamp {
                lastPubMedTimestamp = max(prev, timestamp)
            } else {
                lastPubMedTimestamp = timestamp
            }
        default:
            break
        }
    }

    private func updateCrossrefIntervals(from response: RegistryHTTPResponse, isSearch: Bool) {
        guard let rawLimit = response.headerValue(for: "x-rate-limit-limit")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let limit = Double(rawLimit),
              limit > 0,
              let rawInterval = response.headerValue(for: "x-rate-limit-interval"),
              let intervalSeconds = Self.parseRateLimitIntervalSeconds(rawInterval),
              intervalSeconds > 0 else {
            return
        }
        let spacing = intervalSeconds / limit
        if isSearch {
            crossrefSearchIntervalSeconds = spacing
        } else {
            crossrefSingleIntervalSeconds = spacing
        }
    }

    private func updateOpenAlexBudget(from response: RegistryHTTPResponse) {
        guard let remaining = Self.parseOpenAlexRemainingHeader(from: response) else {
            return
        }
        lastOpenAlexRemainingCredits = remaining
        if remaining < Self.openAlexMinimumSearchCredits {
            openAlexSearchBudgetExhausted = true
        }
    }

    // MARK: - Host Gate Helpers

    private func acquireCrossrefGate() async {
        if !isCrossrefGateHeld {
            isCrossrefGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            crossrefWaiters.append(continuation)
        }
    }

    private func releaseCrossrefGate() {
        if !crossrefWaiters.isEmpty {
            let next = crossrefWaiters.removeFirst()
            next.resume()
        } else {
            isCrossrefGateHeld = false
        }
    }

    private func acquireArXivGate() async {
        if !isArXivGateHeld {
            isArXivGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            arXivWaiters.append(continuation)
        }
    }

    private func releaseArXivGate() {
        if !arXivWaiters.isEmpty {
            let next = arXivWaiters.removeFirst()
            next.resume()
        } else {
            isArXivGateHeld = false
        }
    }

    private func acquirePubMedGate() async {
        if !isPubMedGateHeld {
            isPubMedGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            pubMedWaiters.append(continuation)
        }
    }

    private func releasePubMedGate() {
        if !pubMedWaiters.isEmpty {
            let next = pubMedWaiters.removeFirst()
            next.resume()
        } else {
            isPubMedGateHeld = false
        }
    }

    // MARK: - Header & URL Classification Helpers

    public static func isCrossrefSearchRequest(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        if let query = url.query, !query.isEmpty {
            return true
        }
        let path = url.path
        return path == "/works" || path == "/works/"
    }

    public static func isOpenAlexSearchRequest(_ request: URLRequest, host: String? = nil) -> Bool {
        let resolvedHost = (host ?? request.url?.host?.lowercased()) ?? ""
        guard resolvedHost == "api.openalex.org", let query = request.url?.query?.lowercased() else {
            return false
        }
        return query.contains("search=") || query.contains("search%3d")
    }

    public static func parseOpenAlexRemainingHeader(from response: RegistryHTTPResponse) -> Double? {
        guard let raw = response.headerValue(for: "x-ratelimit-remaining")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let val = Double(raw),
              val.isFinite else {
            return nil
        }
        return val
    }

    public static func parseRateLimitIntervalSeconds(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("ms") {
            guard let ms = Double(trimmed.dropLast(2)), ms > 0 else { return nil }
            return ms / 1000.0
        }
        if trimmed.hasSuffix("s") {
            guard let s = Double(trimmed.dropLast(1)), s > 0 else { return nil }
            return s
        }
        if trimmed.hasSuffix("m") {
            guard let m = Double(trimmed.dropLast(1)), m > 0 else { return nil }
            return m * 60.0
        }
        if trimmed.hasSuffix("h") {
            guard let h = Double(trimmed.dropLast(1)), h > 0 else { return nil }
            return h * 3600.0
        }
        guard let val = Double(trimmed), val > 0 else { return nil }
        return val
    }

    public static func retryWaitSeconds(for response: RegistryHTTPResponse, attemptIndex: Int) -> TimeInterval {
        if let retryAfter = parseRetryAfterSeconds(from: response) {
            return retryAfter
        }
        let idx = min(max(0, attemptIndex), exponentialBackoffSeconds.count - 1)
        return exponentialBackoffSeconds[idx]
    }

    public static func parseRetryAfterSeconds(from response: RegistryHTTPResponse) -> TimeInterval? {
        guard let raw = response.headerValue(for: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if let numeric = Double(raw), numeric.isFinite {
            return min(maxRetryAfterSeconds, max(0.0, numeric))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let targetDate = formatter.date(from: raw) else {
            return nil
        }
        let baseDate: Date = {
            if let rawDate = response.headerValue(for: "Date")?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsedBase = formatter.date(from: rawDate) {
                return parsedBase
            }
            return Date()
        }()
        let delta = targetDate.timeIntervalSince(baseDate)
        return min(maxRetryAfterSeconds, max(0.0, delta))
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

    public static let recordingCapturedHeaderNames: [String] = defaultCapturedHeaderNames + [
        "Date",
        "x-ratelimit-limit",
        "x-ratelimit-reset",
        "x-ratelimit-credits-used"
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
            headers: headers,
            origin: .network,
            fetchedAt: ISO8601DateFormatter().string(from: Date())
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
