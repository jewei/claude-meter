import Foundation
import MeterDomain
import MeterPlatform
import Observation

/// Owns ``Settings`` and saves every change.
///
/// Views bind to ``settings`` directly. The composition root reacts to changes through
/// ``onChange``, so a settings view never calls into providers or the scheduler.
@MainActor @Observable
public final class SettingsStore {
    public static let storageKey = "settings"

    public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            store.set(SettingsCodec.encode(settings), forKey: Self.storageKey)
            onChange?(oldValue, settings)
        }
    }

    /// Called after every saved change with the old and new value.
    @ObservationIgnored public var onChange: ((Settings, Settings) -> Void)?

    @ObservationIgnored private let store: any KeyValueStore

    public init(store: any KeyValueStore) {
        self.store = store
        self.settings = SettingsCodec.decode(store.data(forKey: Self.storageKey))
    }

    /// Changes one setting through a closure, saving once.
    public func update(_ change: (inout Settings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
    }
}
