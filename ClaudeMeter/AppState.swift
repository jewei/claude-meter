import SwiftUI
import WidgetKit
import ClaudeMeterCore

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: ClaudeUsageSnapshot? = nil
    @Published var lastPollResult: ParseResult? = nil
    @Published var isLoading = false
    @Published var lastError: String? = nil
    @Published var lastPolledAt: Date? = nil
    @Published var isPopoverOpen = false

    var pipeline: SnapshotPipeline
    let notificationEngine = NotificationEngine()
    private var pollTask: Task<Void, Never>?
    private var backoffSeconds: Double = 0

    private static let appGroupID = "group.com.claudemeter.app"

    private static func makeStore() -> SnapshotStore {
        (try? SnapshotStore.appGroup(suiteName: appGroupID))
            ?? (try? SnapshotStore.applicationSupport())
            ?? SnapshotStore(directory: FileManager.default.temporaryDirectory)
    }

    init() {
        let store = AppState.makeStore()
        self.pipeline = AppState.makePipeline(store: store)
        self.snapshot = try? store.readLatest()
        self.lastPolledAt = snapshot?.lastSuccessfulPollAt
        if snapshot == nil, let record = try? store.readLastError() {
            self.lastError = record.message
        }
        startPolling()
        Task { await notificationEngine.requestAuthorizationIfNeeded() }
    }

    init(pipeline: SnapshotPipeline, initialSnapshot: ClaudeUsageSnapshot? = nil) {
        self.pipeline = pipeline
        self.snapshot = initialSnapshot
        self.lastPolledAt = initialSnapshot?.lastSuccessfulPollAt
    }

    deinit {
        pollTask?.cancel()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.poll()
            while !Task.isCancelled {
                guard let self else { break }
                let ud = UserDefaults.standard
                let activeInterval = ud.double(forKey: "pollIntervalActiveSeconds").positive ?? 15
                let backgroundInterval = ud.double(forKey: "pollIntervalBackgroundSeconds").positive ?? 60
                let interval = self.isPopoverOpen ? activeInterval : backgroundInterval
                let effective = self.backoffSeconds > 0 ? max(interval, self.backoffSeconds) : interval
                try? await Task.sleep(for: .seconds(effective))
                guard !Task.isCancelled else { break }
                await self.poll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshNow() {
        Task { await poll() }
    }

    func popoverDidOpen() {
        isPopoverOpen = true
        refreshNow()
    }

    func popoverDidClose() {
        isPopoverOpen = false
    }

    var isStale: Bool {
        guard let polledAt = lastPolledAt ?? snapshot?.lastSuccessfulPollAt else { return false }
        let threshold = UserDefaults.standard.double(forKey: "staleAfterSeconds").positive ?? 180
        return Date().timeIntervalSince(polledAt) > threshold
    }

    func rebuildPipeline() {
        let store = AppState.makeStore()
        pipeline = AppState.makePipeline(store: store)
        startPolling()
    }

    var severity: UsageSeverity {
        guard let snap = snapshot else { return .unknown }
        let thresholds = Self.currentThresholds()
        return UsageSeverity.highest(
            thresholds.severity(for: snap.limits.currentSession.percentUsed),
            thresholds.severity(for: snap.limits.currentWeekAllModels.percentUsed)
        )
    }

    static func currentThresholds() -> UsageThresholds {
        let ud = UserDefaults.standard
        let warning = ud.double(forKey: "warningThresholdPercent").positive ?? 80
        let critical = ud.double(forKey: "criticalThresholdPercent").positive ?? 95
        return UsageThresholds(
            warning: warning,
            critical: max(critical, warning + 1)
        )
    }

    private func poll() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await pipeline.poll()
            lastPollResult = result

            if result.isFatal {
                lastError = result.errors.map(\.message).joined(separator: "; ")
                lastPolledAt = Date()
                applyBackoff()
                return
            }

            let previous = snapshot
            if let snap = result.snapshot {
                snapshot = snap
                await notificationEngine.process(
                    snapshot: snap,
                    previous: previous,
                    isStale: false
                )
                WidgetCenter.shared.reloadAllTimelines()
            }
            lastPolledAt = Date()
            lastError = nil
            backoffSeconds = 0
        } catch {
            lastError = String(describing: error)
            lastPolledAt = Date()
            applyBackoff()
        }
    }

    private func applyBackoff() {
        backoffSeconds = backoffSeconds == 0 ? 15 : min(backoffSeconds * 2, 300)
    }

    // MARK: - Pipeline factory

    private static func makePipeline(store: SnapshotStore) -> SnapshotPipeline {
        let ud = UserDefaults.standard
        let cliPath: String = {
            let stored = (ud.string(forKey: "claudeCliPath") ?? "").trimmingCharacters(in: .whitespaces)
            return stored.isEmpty ? (CLIPathDetector.detect() ?? "/usr/local/bin/claude") : stored
        }()
        let statusArgs: [String] = {
            let s = ud.string(forKey: "statusArguments") ?? "status"
            let parts = s.split(separator: " ").map(String.init)
            return parts.isEmpty ? ["status"] : parts
        }()
        let statsArgs: [String]? = {
            let s = (ud.string(forKey: "statsArguments") ?? "stats").trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return nil }
            return s.split(separator: " ").map(String.init)
        }()
        let timeout = ud.double(forKey: "cliTimeoutSeconds").positive ?? 5
        let recordRaw = ud.bool(forKey: "enableDiagnosticsRawOutput")

        return SnapshotPipeline(
            runner: ProcessCommandRunner(config: RunnerConfig(
                cliPath: cliPath,
                statusArguments: statusArgs,
                statsArguments: statsArgs,
                timeoutSeconds: timeout
            )),
            parser: ClaudeOutputParser(cliPath: cliPath),
            store: store,
            recordRawOutput: recordRaw
        )
    }
}

// MARK: - UserDefaults helper

private extension Double {
    var positive: Double? { self > 0 ? self : nil }
}
