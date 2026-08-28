import Foundation

/// The selected-meter file boundary shared by the app publisher and widget reader.
/// Selection validation stays beside I/O so no caller can accidentally accept an
/// old provider, account pin, or revision after a configuration change.
public enum MainMeterPublication {
    public static func load(
        from store: SnapshotStore,
        defaults: UserDefaults = .standard,
        shared: UserDefaults? = AppGroupConfig.sharedDefaults
    ) -> MainMeterReading? {
        guard let reading = try? store.readMainMeter() else { return nil }
        let provider = AppGroupConfig.resolvedMainMeterProvider(
            from: defaults,
            shared: shared)
        let pinnedAccountID: String?
        if case .account(let key) = AppGroupConfig.mainMeterAccountSelection(
            provider: provider,
            defaults: defaults,
            shared: shared)
        {
            pinnedAccountID = key
        } else {
            pinnedAccountID = nil
        }
        guard
            MainMeterPolicy.acceptsPublished(
                reading,
                provider: provider,
                pinnedAccountID: pinnedAccountID,
                selectionRevision: AppGroupConfig.mainMeterRevision(
                    defaults: defaults,
                    shared: shared))
        else { return nil }
        return reading
    }

    public static func replace(
        _ reading: MainMeterReading?,
        in store: SnapshotStore
    ) throws {
        if let reading {
            try store.writeMainMeter(reading)
        } else {
            try store.clearMainMeter()
        }
    }
}
