import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp

/// Connect, Disconnect, and the attempts that overtake or abandon them.
@MainActor
@Suite(.timeLimit(.minutes(1))) final class ClaudeConnectionModelTests {
    private let fixture: ClaudeSettingsFixture

    init() throws {
        fixture = try ClaudeSettingsFixture()
    }

    private var model: ClaudeSettingsModel { fixture.model }
    private var settings: SettingsStore { fixture.settings }
    private var gate: Gate { fixture.gate }

    /// Manual tokens report no plan, so the user picks the badge of the default account.
    @Test func theManualPlanIsTheDefaultAccountsBadge() {
        #expect(model.manualPlan == .pickable(current: nil))
        model.setManualPlan(" Max 5x ")
        #expect(settings.settings.claude.planOverrides["claude"] == "Max 5x")
        #expect(model.manualPlan == .pickable(current: PlanBadge(plan: "Max 5x")))
        model.setManualPlan(nil)
        #expect(settings.settings.claude.planOverrides["claude"] == nil)
    }

    @Test func failedConnectKeepsTheConnectionOff() async {
        #expect(await !model.connectAutomatically())
        #expect(settings.settings.claude.connection == .off)
        #expect(settings.settings.claude.hasConfirmedKeychainAccess)
        #expect(model.message != nil)
        #expect(fixture.credentialChanges == 0)
    }

    @Test func successfulConnectSwitchesToAutomatic() async {
        fixture.storeClaudeCodeLogin()
        gate.open()
        #expect(await model.connectAutomatically())
        #expect(settings.settings.claude.connection == .automatic)
        #expect(model.message == "Connected.")
        #expect(fixture.credentialChanges == 1)
        #expect(!model.isWorking)
    }

    /// Settings shows failures as errors without reading the message text (review UI-33).
    @Test func onlyFailuresAreMarkedAsProblems() async {
        #expect(await !model.connectAutomatically())
        #expect(model.messageIsProblem)
        fixture.storeClaudeCodeLogin()
        gate.open()
        #expect(await model.connectAutomatically())
        #expect(model.message == "Connected.")
        #expect(!model.messageIsProblem)
        fixture.status.withLock { $0 = 401 }
        #expect(await !fixture.connectManually("token"))
        #expect(model.messageIsProblem)
        await model.abandonConnect()
        #expect(model.message == nil)
        #expect(!model.messageIsProblem)
    }

    @Test func reconnectingInTheSameModeRefreshesClaude() async {
        fixture.storeClaudeCodeLogin()
        gate.open()
        #expect(await model.connectAutomatically())
        #expect(await model.connectAutomatically())
        #expect(fixture.credentialChanges == 2)
    }

    @Test func manualReconnectRefreshesClaude() async {
        gate.open()
        #expect(await fixture.connectManually("first"))
        #expect(settings.settings.claude.connection == .manual)
        #expect(await fixture.connectManually("second"))
        #expect(fixture.manualItem?.contains("second") == true)
        #expect(fixture.credentialChanges == 2)
    }

    @Test func failedManualReconnectKeepsTheEarlierConnection() async {
        gate.open()
        #expect(await fixture.connectManually("first"))
        fixture.status.withLock { $0 = 401 }
        #expect(await !fixture.connectManually("second"))
        #expect(settings.settings.claude.connection == .manual)
        #expect(fixture.manualItem?.contains("first") == true)
        #expect(model.message?.contains("rejected") == true)
        #expect(fixture.credentialChanges == 1)
    }

    @Test func anAutomaticConnectAsksForOneRefreshInOneTurn() async {
        fixture.wireLikeTheApp()
        fixture.storeManualLogin("leftover")
        fixture.storeClaudeCodeLogin()
        gate.open()

        #expect(await model.connectAutomatically())

        // The leftover manual login is gone first; then the setting and the credential change
        // come in one turn, so the scheduler merges their refreshes into one.
        #expect(fixture.manualItem == nil)
        #expect(
            Array(fixture.events.prefix(3)) == [
                "connection automatic", "credentials", "next turn",
            ])
    }

    // MARK: - Overtaken and abandoned attempts

    @Test func turningClaudeOffDiscardsALateConnect() async {
        fixture.wireLikeTheApp()
        fixture.storeClaudeCodeLogin()
        let connect = Task { await model.connectAutomatically() }
        #expect(await gate.waitForArrivals())
        settings.update { $0.claude.isEnabled = false }
        gate.open()
        #expect(await !connect.value)
        #expect(settings.settings.claude.connection == .off)
        #expect(model.message == "Claude was turned off, so the connection was not saved.")
        #expect(!model.isWorking)
    }

    @Test func turningClaudeOffDuringAManualConnectStoresNothing() async {
        fixture.wireLikeTheApp()
        fixture.storeManualLogin("old")
        settings.update { $0.claude.connection = .manual }
        let connect = Task { await fixture.connectManually("pasted") }
        #expect(await gate.waitForArrivals())
        settings.update { $0.claude.isEnabled = false }
        gate.open()

        #expect(await !connect.value)

        // The text says that nothing was saved, and nothing was.
        #expect(model.message == "Claude was turned off, so the connection was not saved.")
        #expect(fixture.manualItem?.contains("old") == true)
        #expect(settings.settings.claude.connection == .manual)
        #expect(fixture.credentialChanges == 0)
    }

    @Test func newerAttemptWinsOverOlder() async {
        fixture.storeClaudeCodeLogin()
        let connect = Task { await model.connectAutomatically() }
        #expect(await gate.waitForArrivals())
        await model.disconnect()
        gate.open()
        #expect(await !connect.value)
        #expect(settings.settings.claude.connection == .off)
        #expect(!model.isWorking)
    }

    @Test func anAbandonedManualConnectStoresNothing() async {
        let connect = Task { await fixture.connectManually("pasted") }
        #expect(await gate.waitForArrivals())
        await model.abandonConnect()
        #expect(!model.isWorking)
        gate.open()
        #expect(await !connect.value)
        #expect(fixture.manualItem == nil)
        #expect(settings.settings.claude.connection == .off)
        #expect(model.message == nil)
    }

    @Test func turningClaudeOffDuringADisconnectStillDisconnects() async {
        fixture.wireLikeTheApp()
        gate.open()
        #expect(await fixture.connectManually("token"))
        fixture.deletes.turnOn()
        let disconnect = Task { await model.disconnect() }
        #expect(await waitUntil { fixture.deletes.arrivals > 0 })

        settings.update { $0.claude.isEnabled = false }
        // What the app does when Claude is turned off while Settings works.
        await model.abandonConnect()
        fixture.deletes.turnOff()
        await disconnect.value

        #expect(settings.settings.claude.connection == .off)
        #expect(fixture.manualItem == nil)
        #expect(!model.isWorking)
    }

    // MARK: - Disconnect and leftover manual logins

    @Test func disconnectManualDeletesTheItem() async {
        gate.open()
        #expect(await fixture.connectManually("token"))
        #expect(fixture.manualItem != nil)
        await model.disconnect()
        #expect(fixture.manualItem == nil)
        #expect(settings.settings.claude.connection == .off)
        #expect(fixture.credentialChanges == 2)
    }

    @Test func aFailedDisconnectStillTurnsTheConnectionOff() async {
        gate.open()
        #expect(await fixture.connectManually("token"))
        fixture.keychain.failure = .unavailable

        await model.disconnect()

        #expect(settings.settings.claude.connection == .off)
        #expect(
            model.message
                == "Disconnected, but the saved Claude tokens could not be deleted. Claude Meter "
                + "will try again.")
        #expect(model.messageIsProblem)
        #expect(fixture.credentialChanges == 2)
        #expect(!model.isWorking)

        // The next reload, as at the next launch, deletes the item.
        fixture.keychain.failure = nil
        await model.reload()
        #expect(fixture.manualItem == nil)
        #expect(model.manualStatus == .signedOut)
    }

    @Test func aManualLoginThatNoConnectionUsesIsDeletedAtReload() async {
        fixture.storeManualLogin("leftover")
        settings.update { $0.claude.connection = .automatic }
        await model.reload()
        #expect(fixture.manualItem == nil)

        // A manual connection keeps its login while the Claude switch is off.
        fixture.storeManualLogin("kept")
        settings.update {
            $0.claude.connection = .manual
            $0.claude.isEnabled = false
        }
        await model.reload()
        #expect(fixture.manualItem?.contains("kept") == true)
        #expect(model.manualStatus == .signedIn)
    }

    @Test func automaticConnectDeletesALeftoverManualLogin() async {
        gate.open()
        #expect(await fixture.connectManually("manual-token"))
        #expect(fixture.manualItem != nil)
        fixture.storeClaudeCodeLogin()
        #expect(await model.connectAutomatically())
        #expect(settings.settings.claude.connection == .automatic)
        #expect(fixture.manualItem == nil)
    }

    @Test func disconnectInAutomaticModeAlsoDeletesTheManualItem() async {
        fixture.storeManualLogin("old")
        settings.update { $0.claude.connection = .automatic }
        await model.disconnect()
        #expect(settings.settings.claude.connection == .off)
        #expect(fixture.manualItem == nil)
    }
}
