import MeterApp
import MeterPlatform
import Testing

@testable import MeterUI

/// The launch-at-login error stays until macOS reports the chosen state (review R4-U-02).
@MainActor @Suite struct LaunchAtLoginStateTests {
    private let failure = "Claude Meter could not turn on launch at login."

    @Test func aFailedChangeKeepsItsErrorWhileMacOSDisagrees() {
        let macOS = FakeLoginItem()
        macOS.failure = failure
        let state = macOS.state()
        state.choose(true)
        #expect(state.error.text == failure)
        #expect(state.status == .disabled)
        // The page shows again, or the app becomes active: macOS still says off.
        state.read()
        #expect(state.error.text == failure)
    }

    @Test func theErrorGoesWhenMacOSReportsTheChoice() {
        let macOS = FakeLoginItem()
        macOS.failure = failure
        let state = macOS.state()
        state.choose(true)
        macOS.status = .enabled
        state.read()
        #expect(state.error.text == nil)
        #expect(state.status == .enabled)
    }

    @Test func aChangeThatWorksShowsNoError() {
        let macOS = FakeLoginItem()
        let state = macOS.state()
        macOS.status = .requiresApproval
        state.choose(true)
        #expect(state.error.text == nil)
        #expect(state.status.isOn)
    }
}
