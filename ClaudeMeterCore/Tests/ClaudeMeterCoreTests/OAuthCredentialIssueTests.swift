import Foundation
import Testing

@testable import ClaudeMeterCore

@Suite("OAuthCredentialIssue")
struct OAuthCredentialIssueTests {

    private func attempts(
        _ reason: SourceAttempt.Reason,
        outcome: SourceAttempt.Outcome = .skipped
    ) -> [SourceAttempt] {
        [
            SourceAttempt(source: .statusline, outcome: .skipped, reason: .staleData),
            SourceAttempt(source: .oauth, outcome: outcome, reason: reason),
            SourceAttempt(source: .cache, outcome: .selected, reason: .cachedSnapshot),
        ]
    }

    @Test func mapsActionableCredentialFailures() {
        #expect(
            OAuthCredentialIssue.from(sourceAttempts: attempts(.credentialsMissing)) == .signedOut)
        #expect(
            OAuthCredentialIssue.from(sourceAttempts: attempts(.refreshRejected, outcome: .failed))
                == .signInExpired)
        #expect(
            OAuthCredentialIssue.from(sourceAttempts: attempts(.unauthorized, outcome: .failed))
                == .signInExpired)
        #expect(
            OAuthCredentialIssue.from(sourceAttempts: attempts(.credentialsInvalid)) == .corrupt)
    }

    @Test func mapsSelfResolvingStatesWithoutAlarming() {
        let locked = OAuthCredentialIssue.from(sourceAttempts: attempts(.credentialsUnavailable))
        #expect(locked == .keychainLocked)
        #expect(locked?.needsUserAction == false)

        let deferred = OAuthCredentialIssue.from(sourceAttempts: attempts(.refreshDeferred))
        #expect(deferred == .retrying)
        #expect(deferred?.needsUserAction == false)
    }

    /// A user who never connected OAuth, or switched the source off, chose that —
    /// warning them would be noise.
    @Test func ignoresDeliberateAndUnactionableStates() {
        for reason: SourceAttempt.Reason in [
            .notConnected, .sourceDisabled, .networkError, .requestFailed,
            .invalidResponse,
        ] {
            #expect(
                OAuthCredentialIssue.from(sourceAttempts: attempts(reason)) == nil,
                "\(reason) should not raise a credential notice")
        }
    }

    /// Throttling is the one un-actionable state we *do* surface: a 429 can carry
    /// an hour-long `Retry-After`, and an hour of frozen numbers with no
    /// explanation is indistinguishable from a broken app.
    @Test func surfacesThrottlingInTheInformationalTone() {
        let issue = OAuthCredentialIssue.from(sourceAttempts: attempts(.rateLimited))
        #expect(issue == .rateLimited)
        #expect(issue?.needsUserAction == false)
    }

    @Test func throttleNoticeCountsDownWhenADeadlineIsKnown() {
        let now = Date()
        let text = OAuthCredentialIssue.rateLimited.displayText(
            retryAt: now.addingTimeInterval(48 * 60), now: now)
        #expect(text.contains("48m"))
        #expect(!text.contains("shortly"))
    }

    /// No deadline, or one already elapsed, must not invent a time.
    @Test func throttleNoticeDegradesWithoutAUsableDeadline() {
        let now = Date()
        #expect(OAuthCredentialIssue.rateLimited.displayText(now: now).contains("shortly"))
        #expect(
            OAuthCredentialIssue.rateLimited
                .displayText(retryAt: now.addingTimeInterval(-60), now: now)
                .contains("shortly"))
    }

    @Test func ignoresASuccessfulOAuthPoll() {
        #expect(
            OAuthCredentialIssue.from(sourceAttempts: attempts(.freshData, outcome: .selected))
                == nil)
    }

    @Test func ignoresPollsThatNeverTouchedOAuth() {
        let noOAuth = [
            SourceAttempt(source: .statusline, outcome: .selected, reason: .freshData)
        ]
        #expect(OAuthCredentialIssue.from(sourceAttempts: noOAuth) == nil)
        #expect(OAuthCredentialIssue.from(sourceAttempts: []) == nil)
    }

    /// Every actionable case must be one the user can actually resolve, and every
    /// non-actionable one must clear itself — the popover picks its tone from this.
    @Test func actionabilityIsExhaustivelyClassified() {
        let actionable = OAuthCredentialIssue.allCases.filter(\.needsUserAction)
        #expect(Set(actionable) == [.signedOut, .signInExpired, .corrupt])
    }
}
