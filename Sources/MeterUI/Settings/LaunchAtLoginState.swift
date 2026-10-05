import MeterApp
import MeterPlatform
import Observation

/// The launch-at-login switch's status and error.
///
/// The Settings window controller keeps it, like ``SettingsNavigation``, so the error stays
/// when the user changes tabs or closes the window while macOS still disagrees with the
/// choice. It goes only when macOS reports the state that the user chose
/// (``LaunchAtLoginError``).
@MainActor @Observable final class LaunchAtLoginState {
    /// The state that macOS reported last.
    private(set) var status = LoginItem.Status.disabled
    private(set) var error = LaunchAtLoginError()

    @ObservationIgnored private let readStatus: @MainActor () -> LoginItem.Status
    @ObservationIgnored private let setEnabled: @MainActor (Bool) -> String?

    /// `readStatus` and `setEnabled` are `LoginItem`'s; tests pass fakes.
    init(
        readStatus: @escaping @MainActor () -> LoginItem.Status = { LoginItem.status },
        setEnabled: @escaping @MainActor (Bool) -> String? = { LoginItem.setEnabled($0) }
    ) {
        self.readStatus = readStatus
        self.setEnabled = setEnabled
    }

    /// Reads the state from macOS. The error goes when the state agrees with the user's choice.
    func read() {
        status = readStatus()
        error.read(status)
    }

    /// The user turned the switch to `isOn`.
    func choose(_ isOn: Bool) {
        error.chose(isOn, error: setEnabled(isOn))
        read()
    }
}
