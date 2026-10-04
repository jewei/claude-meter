import MeterPlatform
import Testing

@testable import MeterApp

/// The launch-at-login error goes when macOS agrees with the user (review R3-U-07).
@Suite struct LaunchAtLoginErrorTests {
    private let failure = "Claude Meter could not turn on launch at login."

    @Test func aFailedChangeShowsItsError() {
        var error = LaunchAtLoginError()
        #expect(error.text == nil)
        error.chose(true, error: failure)
        #expect(error.text == failure)
    }

    @Test func theErrorStaysWhileMacOSDisagrees() {
        var error = LaunchAtLoginError()
        error.chose(true, error: failure)
        error.read(.disabled)
        error.read(.unavailable)
        #expect(error.text == failure)
    }

    @Test func theErrorGoesWhenMacOSAgreesWithTheChoice() {
        var on = LaunchAtLoginError()
        on.chose(true, error: failure)
        on.read(.enabled)
        #expect(on.text == nil)

        var waiting = LaunchAtLoginError()
        waiting.chose(true, error: failure)
        waiting.read(.requiresApproval)
        #expect(waiting.text == nil)

        var off = LaunchAtLoginError()
        off.chose(false, error: "Claude Meter could not turn off launch at login.")
        off.read(.enabled)
        #expect(off.text != nil)
        off.read(.disabled)
        #expect(off.text == nil)
        // A later status does not bring the error back.
        off.read(.enabled)
        #expect(off.text == nil)
    }

    @Test func aChangeThatWorksClearsTheError() {
        var error = LaunchAtLoginError()
        error.chose(true, error: failure)
        error.chose(false, error: nil)
        #expect(error.text == nil)
        error.read(.enabled)
        #expect(error.text == nil)
    }
}
