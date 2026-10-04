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
