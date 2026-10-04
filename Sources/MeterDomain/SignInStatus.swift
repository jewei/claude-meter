/// Whether a provider has a usable login, for Settings and onboarding. Checks never read
/// secrets when the system offers an attributes-only lookup.
public enum SignInStatus: Hashable, Sendable {
    case signedIn
    case signedOut
    /// The check failed for a temporary reason, such as a locked Keychain.
    case unknown(Reason)

    /// Why a check could not decide. The text reaches Settings and Diagnostics, so it is
    /// always redacted: the only way to make a reason is through ``Redactor``.
    public struct Reason: Hashable, Sendable, CustomStringConvertible {
        public let text: String

        public init(_ text: String) {
            self.text = Redactor.redact(text)
        }

        public var description: String { text }
    }

    /// An unknown status with a redacted reason, so callers can pass any text.
    public static func unknown(_ reason: String) -> SignInStatus {
        .unknown(Reason(reason))
    }
}
