import MeterPlatform

@testable import MeterUI

/// macOS as the launch-at-login switch sees it, so no test registers a real login item.
@MainActor final class FakeLoginItem {
    var status = LoginItem.Status.disabled
    /// The error of the next change, or nil when it works.
    var failure: String?

    func state() -> LaunchAtLoginState {
        LaunchAtLoginState(readStatus: { self.status }, setEnabled: { _ in self.failure })
    }
}
