import ClaudeMeterProviders
import Darwin
import Dispatch

struct MemoryPressureTrimSummary: Equatable, Sendable {
    let costEntries: Int
    let activityEntries: Int

    var total: Int { costEntries + activityEntries }
}

/// Yields rebuildable transcript caches when macOS reports memory pressure.
/// The dispatch source runs on a utility queue, then hops to `MainActor` for the
/// app-owned lifecycle; each cache owns its own lock, and allocator relief stays
/// off-main because it can briefly walk malloc zones.
@MainActor
final class MemoryPressureMonitor {
    typealias TrimHandler = @MainActor () -> MemoryPressureTrimSummary

    private let trimCaches: TrimHandler
    private let releaseFreeMallocPages: @Sendable () -> Void
    private var source: DispatchSourceMemoryPressure?

    init(
        trimCaches: @escaping TrimHandler = {
            MemoryPressureTrimSummary(
                costEntries: CostUsageCache.shared.trimMemory(),
                activityEntries: ActivityCache.shared.trimMemory())
        },
        releaseFreeMallocPages: @escaping @Sendable () -> Void = {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    ) {
        self.trimCaches = trimCaches
        self.releaseFreeMallocPages = releaseFreeMallocPages
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility))
        source.setEventHandler(
            handler: Self.makeEventHandler { [weak self] in
                self?.handleMemoryPressure()
            })
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    nonisolated static func makeEventHandler(
        handle: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { @Sendable in
            Task { @MainActor in handle() }
        }
    }

    @discardableResult
    func handleMemoryPressureForTesting() -> MemoryPressureTrimSummary {
        handleMemoryPressure()
    }

    @discardableResult
    private func handleMemoryPressure() -> MemoryPressureTrimSummary {
        let summary = trimCaches()
        let release = releaseFreeMallocPages
        Task.detached(priority: .utility) { release() }
        return summary
    }

    deinit {
        source?.cancel()
    }
}
