import Foundation
import Testing

@testable import MeterApp

/// The manual token form's draft rules (review R3-U-09).
@Suite struct ManualTokenDraftTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func theExpiryStartsEightHoursAhead() {
        let draft = ManualTokenDraft(now: now)
        #expect(draft.expiry == now.addingTimeInterval(8 * 3_600))
        #expect(!draft.hasExpiry)
    }

    @Test func pastedTokensLoseSurroundingSpaceAndLineBreaks() throws {
        var draft = ManualTokenDraft(now: now)
        draft.accessToken = "  sk-ant-oat01-a\n"
        draft.refreshToken = "\t sk-ant-ort01-r \n"
        let submission = try #require(draft.submission)
        #expect(submission.accessToken == "sk-ant-oat01-a")
        #expect(submission.refreshToken == "sk-ant-ort01-r")
        #expect(submission.expiresAt == nil)
    }

    @Test func aBlankRefreshTokenIsLeftOut() throws {
        var draft = ManualTokenDraft(now: now)
        draft.accessToken = "a"
        draft.refreshToken = " \n "
        #expect(try #require(draft.submission).refreshToken == nil)
    }

    @Test func theExpiryIsSentOnlyWhenSet() throws {
        var draft = ManualTokenDraft(now: now)
        draft.accessToken = "a"
        draft.hasExpiry = true
        #expect(try #require(draft.submission).expiresAt == draft.expiry)
    }

    @Test func connectNeedsAnAccessTokenAndNoRunningCheck() {
        var draft = ManualTokenDraft(now: now)
        #expect(!draft.canConnect(isWorking: false))
        draft.refreshToken = "r"
        #expect(!draft.canConnect(isWorking: false))
        #expect(draft.submission == nil)
        draft.accessToken = "   "
        #expect(!draft.canConnect(isWorking: false))
        draft.accessToken = "a"
        #expect(draft.canConnect(isWorking: false))
        #expect(!draft.canConnect(isWorking: true))
    }

    /// A stray Escape never loses pasted tokens.
    @Test func escapeCancelsOnlyWhileBothTokenFieldsAreEmpty() {
        var draft = ManualTokenDraft(now: now)
        #expect(draft.escapeCancels)
        draft.accessToken = " \n"
        #expect(draft.escapeCancels)
        draft.refreshToken = "r"
        #expect(!draft.escapeCancels)
        draft.refreshToken = ""
        draft.accessToken = "a"
        #expect(!draft.escapeCancels)
    }
}
