import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct SettingsTextTests {
    @Test func claudeSubtitleFollowsTheConnection() {
        #expect(
            DataSourceText.claudeSubtitle(connection: .off, isEnabled: true)
                == "Not connected. Choose a connection below.")
        #expect(
            DataSourceText.claudeSubtitle(connection: .off, isEnabled: false)
                == "Not connected. Turn on this source to set it up.")
        #expect(
            DataSourceText.claudeSubtitle(connection: .automatic, isEnabled: true)
                == "Connected. Reads Claude Code's login from the Keychain.")
        #expect(
            DataSourceText.claudeSubtitle(connection: .manual, isEnabled: false)
                == "Connected. This source is off.")
    }

    /// The connection controls are hidden while Claude is off, so the subtitle says that
    /// turning Claude off kept a Connect from being saved, and only while Claude is off
    /// (review R3-U-06).
    @Test func claudeSubtitleSaysAConnectWasNotSavedWhileClaudeIsOff() {
        #expect(
            DataSourceText.claudeSubtitle(
                connection: .off, isEnabled: false, connectWasNotSaved: true)
                == "Not connected. Claude was turned off, so the connection was not saved.")
        #expect(
            DataSourceText.claudeSubtitle(
                connection: .manual, isEnabled: false, connectWasNotSaved: true)
                == "Connected as before. Claude was turned off, so the new connection was not "
                + "saved.")
        #expect(
            DataSourceText.claudeSubtitle(
                connection: .off, isEnabled: true, connectWasNotSaved: true)
                == "Not connected. Choose a connection below.")
    }

    @Test func signInStatesNameTheProblem() {
        #expect(DataSourceText.claudeCode(.signedIn).isSignedIn)
        #expect(DataSourceText.claudeCode(.signedOut).isProblem)
        #expect(!DataSourceText.claudeCode(nil).isProblem)
        #expect(
            DataSourceText.claudeCode(.unknown("The Keychain is locked.")).text
                == "Could not check Claude Code's login. The Keychain is locked.")
        #expect(DataSourceText.manualTokens(.signedOut).text == "No tokens are saved.")
        #expect(!DataSourceText.manualTokens(.signedOut).isProblem)
        #expect(DataSourceText.codexHome(.signedOut).isProblem)
        #expect(DataSourceText.codexHome(.unknown("Codex detected.")).text == "Codex detected.")
    }

    /// Manual tokens must come from a separate login (claude-oauth.md, Manual mode rule 11).
    @Test func manualTokensNameTheirSource() {
        let note = DataSourceText.manualTokensSource
        #expect(note.contains("separate Claude login"))
        #expect(note.contains("not Claude Code's own login"))
        #expect(note.contains("sign Claude Code out"))
    }

    @Test func disconnectAsksOnlyWhenEnteredTokensWouldBeLost() {
        let manual = DataSourceText.disconnectConfirmation(connection: .manual, manualStatus: nil)
        #expect(manual?.title == "Delete the saved tokens?")
        #expect(manual?.confirmTitle == "Disconnect and Delete Tokens")
        #expect(
            DataSourceText.disconnectConfirmation(connection: .automatic, manualStatus: .signedIn)
                == manual)
        #expect(
            DataSourceText.disconnectConfirmation(connection: .automatic, manualStatus: .signedOut)
                == nil)
        #expect(
            DataSourceText.disconnectConfirmation(
                connection: .automatic, manualStatus: .unknown("Locked")) == nil)
        #expect(DataSourceText.disconnectConfirmation(connection: .off, manualStatus: nil) == nil)
    }

    @Test func removalNamesTheFolderAndWhatGoes() {
        let confirmation = DataSourceText.removeConfirmation(name: "Work")
        #expect(confirmation.title == "Remove Work?")
        #expect(confirmation.message.contains("The folder stays on disk."))
        #expect(confirmation.confirmTitle == "Remove")
    }

    @Test func untrackedLoginsSayItInWords() {
        #expect(DataSourceText.trackingChip(isEnabled: false) == "Not tracked")
        #expect(DataSourceText.trackingChip(isEnabled: true) == nil)
    }

    /// A reported plan wins; otherwise the user may pick one (review UI-39).
    @Test func planChoiceFollowsTheReportedPlan() throws {
        let max = try #require(PlanBadge(plan: "Max 20x"))
        #expect(PlanChoice(reported: "Max 20x", override: "Team") == .reported(max))
        #expect(
            PlanChoice(reported: nil, override: "Team")
                == .pickable(current: PlanBadge(plan: "Team")))
        #expect(PlanChoice(reported: " ", override: nil) == .pickable(current: nil))
        #expect(PlanChoice.plans.first == "Pro")
        #expect(PlanChoice.plans.allSatisfy { PlanBadge(plan: $0) != nil })
    }

    @Test func avatarInitials() {
        #expect(DataSourceText.initial("work") == "W")
        #expect(DataSourceText.initial(".claude-2") == "C")
        #expect(DataSourceText.initial("—") == "?")
    }

    @Test func cardOrderHintOffersResetOnlyForASavedChoice() {
        var settings = Settings()
        #expect(!CardOrderHint(settings).canReset)
        #expect(CardOrderHint(settings).text == "Drag cards in the popover to change their order.")
        settings.menuBar.pinnedAccounts[.codex] = "/h"
        #expect(CardOrderHint(settings).canReset)
        settings.menuBar.pinnedAccounts = [:]
        settings.cards.order = [.extraUsage]
        #expect(
            CardOrderHint(settings).text
                == "Your order is saved. Drag cards in the popover to change it.")
    }

    @Test func lastCheckedText() {
        let now = Date.reference()
        #expect(UpdateCheckText.lastChecked(nil, now: now) == "Not checked yet")
        #expect(UpdateCheckText.lastChecked(.reference(-30), now: now) == "Last checked just now")
        #expect(UpdateCheckText.lastChecked(.reference(30), now: now) == "Last checked just now")
        #expect(UpdateCheckText.lastChecked(.reference(-600), now: now) == "Last checked 10m ago")
        #expect(UpdateCheckText.lastChecked(.reference(-7_200), now: now) == "Last checked 2h ago")
        #expect(
            UpdateCheckText.lastChecked(.reference(-200_000), now: now) == "Last checked 2d ago")
    }

    /// An unknown version is not a success (review UI-34).
    @Test func statusToneFollowsWhatIsKnown() {
        let current = UpdateCheckText.statusLine(
            version: "4.0.0", build: "400", isUpdateAvailable: false, canUpdate: true)
        #expect(current.text == "Installed v4.0.0 (400)")
        #expect(current.tone == .current)
        let unknown = UpdateCheckText.statusLine(
            version: nil, build: nil, isUpdateAvailable: false, canUpdate: true)
        #expect(unknown.text == "Installed version unknown")
        #expect(unknown.tone == .neutral)
        #expect(
            UpdateCheckText.statusLine(
                version: "", build: "1", isUpdateAvailable: false, canUpdate: true
            ).tone
                == .neutral)
        let update = UpdateCheckText.statusLine(
            version: nil, build: nil, isUpdateAvailable: true, canUpdate: true)
        #expect(update.tone == .attention)
    }

    /// A development or unsigned build says so, never "up to date" (review UI-52).
    @MainActor @Test func aBuildThatCannotUpdateSaysSo() {
        let line = UpdateCheckText.statusLine(
            version: "4.0.0", build: "400", isUpdateAvailable: true, canUpdate: false)
        #expect(line.text == UpdateCheckText.unavailable)
        #expect(line.tone == .neutral)
        let updater = DisabledUpdater()
        #expect(!updater.isAvailable)
    }

    @Test func installedVersion() {
        #expect(
            UpdateCheckText.status(version: "4.0.0", build: "400", isUpdateAvailable: false)
                == "Installed v4.0.0 (400)")
        #expect(
            UpdateCheckText.status(version: "4.0.0", build: nil, isUpdateAvailable: false)
                == "Installed v4.0.0")
        #expect(
            UpdateCheckText.status(version: nil, build: nil, isUpdateAvailable: true)
                == "An update is available.")
    }
}
