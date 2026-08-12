import Foundation

/// A credential problem worth telling the user about, derived from a poll's
/// `sourceAttempts` trail.
///
/// The OAuth tier fails silently by design — every failure falls through to the
/// next source, so the meter keeps showing *something*. That's right for
/// transient faults and wrong for a dead sign-in: without a notice, a user whose
/// refresh token was revoked just sees numbers quietly stop moving, with the
/// cause visible only in Diagnostics.
public enum OAuthCredentialIssue: String, Sendable, Equatable, CaseIterable {
    /// Claude Code has no stored credentials — never signed in, or signed out.
    case signedOut
    /// The stored refresh token was rejected (`invalid_grant`). Only a new stored
    /// token recovers this; the app cannot refresh its way out.
    case signInExpired
    /// Stored credentials exist but couldn't be parsed.
    case corrupt
    /// The Keychain is locked or the read was denied — transient, resolves once
    /// the Mac is unlocked.
    case keychainLocked
    /// Backing off after transient refresh failures; recovers on its own.
    case retrying
    /// Anthropic is throttling us (HTTP 429). Nothing to fix — but without a
    /// notice, a multi-minute `Retry-After` looks exactly like the app being
    /// broken: the numbers simply stop moving.
    case rateLimited

    /// `true` when the user has to do something; `false` for states that clear
    /// themselves. Callers use this to pick an alarming vs. informational tone.
    public var needsUserAction: Bool {
        switch self {
        case .signedOut, .signInExpired, .corrupt: return true
        case .keychainLocked, .retrying, .rateLimited: return false
        }
    }

    /// One line naming the problem and its exact fix. Lives here (like
    /// `ResetPhrase` and `UsagePace.displayName`) because both the popover banner
    /// and the Settings row show the same sentence.
    ///
    /// Every actionable case points at `claude login`: a rejected refresh token can
    /// only be replaced by Claude Code writing a new one. Disconnecting in Settings
    /// clears our in-memory cache but leaves the dead token in the Keychain, so it
    /// would not help — don't reword these toward the app's own controls.
    /// - Parameter retryAt: when the throttle lifts, for `.rateLimited` only.
    ///   Phrased through `ResetPhrase` like every other wait in the app, so a
    ///   throttle reads in the same units as a window reset. Omitted or already
    ///   elapsed → the sentence degrades to "shortly" rather than inventing a time.
    public func displayText(retryAt: Date? = nil, now: Date = Date()) -> String {
        switch self {
        case .signedOut:
            "Claude Code isn't signed in — run `claude login` to restore Opus and plan details"
        case .signInExpired:
            "Claude Code sign-in expired — run `claude login` to restore Opus and plan details"
        case .corrupt:
            "Claude Code credentials couldn't be read — run `claude login` to re-create them"
        case .keychainLocked:
            "Keychain is locked — unlock your Mac to refresh Opus and plan details"
        case .retrying:
            "Retrying the Claude Code sign-in…"
        case .rateLimited:
            if let retryAt, let phrase = ResetPhrase.spoken(until: retryAt, asOf: now) {
                "Anthropic is rate-limiting usage checks — retrying \(phrase)"
            } else {
                "Anthropic is rate-limiting usage checks — retrying shortly"
            }
        }
    }

    /// Classifies the OAuth step of a poll. Returns `nil` when OAuth succeeded,
    /// wasn't configured, or failed for a reason that resolves itself within a
    /// poll or two (network blip, server error) — those are the pipeline's job to
    /// retry, not the user's problem to solve.
    ///
    /// `rateLimited` is the exception among the un-actionable reasons: a 429 can
    /// carry an hour-long `Retry-After`, and a full hour of frozen numbers with no
    /// explanation is indistinguishable from a broken app. It surfaces in the
    /// informational tone (`needsUserAction == false`) — naming the cause, not
    /// asking for a fix.
    ///
    /// `notConnected` and `sourceDisabled` are deliberately excluded: the user
    /// chose those, so a warning would be noise.
    public static func from(sourceAttempts: [SourceAttempt]) -> OAuthCredentialIssue? {
        guard let attempt = sourceAttempts.first(where: { $0.source == .oauth }),
            attempt.outcome != .selected
        else { return nil }

        switch attempt.reason {
        case .credentialsMissing: return .signedOut
        case .refreshRejected, .unauthorized: return .signInExpired
        case .credentialsInvalid: return .corrupt
        case .credentialsUnavailable: return .keychainLocked
        case .refreshDeferred, .refreshFailed: return .retrying
        case .rateLimited: return .rateLimited
        case .freshData, .sourceDisabled, .notConnected, .staleData, .noData, .cooldown,
            .networkError, .invalidResponse, .requestFailed, .cachedSnapshot,
            .cacheMissing, .cacheUnreadable:
            return nil
        }
    }
}
