/// Whether a provider has a usable login, for Settings and onboarding. Checks never read
/// secrets when the system offers an attributes-only lookup.
public enum SignInStatus: Hashable, Sendable {
    case signedIn
    case signedOut
    /// The check failed for a temporary reason, such as a locked Keychain.
    case unknown(String)
}

/// One labeled fact for the Diagnostics view. Values are redacted.
public struct DiagnosticFact: Hashable, Sendable {
    public let label: String
    public let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = Redactor.redact(value)
    }
}

/// A provider that can describe its sources and recent attempts for Diagnostics.
public protocol DiagnosticsReporting: Sendable {
    func diagnostics() async -> [DiagnosticFact]
}
