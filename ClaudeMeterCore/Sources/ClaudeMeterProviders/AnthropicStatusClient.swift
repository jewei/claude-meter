import ClaudeMeterCore
import Foundation

/// Severity of an Anthropic service incident, mapped from the Statuspage.io
/// `status.indicator` field.
public enum ServiceStatusLevel: String, Codable, Equatable, Sendable {
    case operational  // "none"
    case minor
    case major
    case critical

    /// Maps the Statuspage `indicator` string; unknown values are treated as minor.
    public static func from(indicator: String) -> ServiceStatusLevel {
        switch indicator.lowercased() {
        case "none": return .operational
        case "minor": return .minor
        case "major": return .major
        case "critical": return .critical
        default: return .minor
        }
    }

    /// `true` for anything worth surfacing to the user.
    public var isIncident: Bool { self != .operational }
}

public struct ServiceStatus: Equatable, Sendable {
    public let level: ServiceStatusLevel
    public let description: String

    public init(level: ServiceStatusLevel, description: String) {
        self.level = level
        self.description = description
    }
}

/// Reads Anthropic's public Statuspage.io summary to distinguish a real outage
/// from bad credentials when usage refreshes fail.
public struct AnthropicStatusClient: Sendable {

    private static let statusURL = URL(string: "https://status.anthropic.com/api/v2/status.json")!

    /// How long a fetched status is reused before hitting the network again.
    /// The app polls Claude every 60 s, but Statuspage asks integrators not to
    /// poll faster than every 5 minutes — and this is advisory data that only
    /// renders a banner. Without this cache it would be the app's
    /// highest-frequency third-party request at ~1440/day.
    static let cacheTTL: TimeInterval = 5 * 60

    private static let lock = NSLock()
    private static nonisolated(unsafe) var memo: (fetchedAt: Date, status: ServiceStatus?)?

    private let transport: any HTTPTransport
    /// The memo is process-wide, so it only applies to the one real endpoint. An
    /// injected (stub) transport bypasses it entirely — otherwise one test's
    /// canned response would leak into the next.
    private let usesSharedTransport: Bool

    public init(transport: any HTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
        self.usesSharedTransport = (transport as AnyObject) === ProviderHTTPClient.shared
    }

    /// Fetches the current status, or `nil` on any failure (status is advisory only).
    /// Results — including a `nil` "couldn't tell" — are memoized for `cacheTTL`.
    public func fetch(now: Date = Date()) async -> ServiceStatus? {
        if usesSharedTransport, let cached = Self.freshMemo(now: now) { return cached }
        let request = URLRequest(url: Self.statusURL)
        guard let (data, http) = try? await transport.send(request, retry: .transient),
            http.statusCode == 200
        else {
            if usesSharedTransport { Self.setMemo(nil, now: now) }
            return nil
        }
        let status = Self.parse(data)
        if usesSharedTransport { Self.setMemo(status, now: now) }
        return status
    }

    private static func freshMemo(now: Date) -> ServiceStatus?? {
        lock.lock()
        defer { lock.unlock() }
        guard let memo, now.timeIntervalSince(memo.fetchedAt) < cacheTTL else { return nil }
        return .some(memo.status)
    }

    private static func setMemo(_ status: ServiceStatus?, now: Date) {
        lock.lock()
        memo = (now, status)
        lock.unlock()
    }

    static func resetMemoForTesting() {
        lock.lock()
        memo = nil
        lock.unlock()
    }

    static func parse(_ data: Data) -> ServiceStatus? {
        guard let decoded = try? JSONDecoder().decode(StatusResponse.self, from: data) else {
            return nil
        }
        return ServiceStatus(
            level: .from(indicator: decoded.status.indicator),
            description: decoded.status.description
        )
    }
}

private struct StatusResponse: Decodable {
    let status: Status
    struct Status: Decodable {
        let indicator: String
        let description: String
    }
}
