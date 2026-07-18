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

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = ProviderHTTPClient.shared) {
        self.transport = transport
    }

    /// Fetches the current status, or `nil` on any failure (status is advisory only).
    public func fetch() async -> ServiceStatus? {
        let request = URLRequest(url: Self.statusURL)
        guard let (data, http) = try? await transport.send(request, retry: .transient),
            http.statusCode == 200
        else {
            return nil
        }
        return Self.parse(data)
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
