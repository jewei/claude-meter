import MeterPlatform

/// The error under the launch-at-login switch.
///
/// It shows after a change fails and stays until macOS reports the state that the user chose,
/// for example after the user fixes it in System Settings. A login item that waits for
/// approval counts as on (`LoginItem.Status.isOn`).
public struct LaunchAtLoginError: Equatable, Sendable {
    /// The text to show, or nil.
    public private(set) var text: String?
    /// The state that the user chose when the change failed.
    private var choice: Bool?

    public init() {}

    /// The user turned the switch to `isOn`. `error` is nil when the change worked.
    public mutating func chose(_ isOn: Bool, error: String?) {
        text = error
        choice = error == nil ? nil : isOn
    }

    /// A fresh status from macOS. The error goes when the status agrees with the user's last
    /// choice.
    public mutating func read(_ status: LoginItem.Status) {
        guard let choice, status.isOn == choice else { return }
        text = nil
        self.choice = nil
    }
}
