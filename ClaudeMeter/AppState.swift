import SwiftUI
import ClaudeMeterCore

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: ClaudeUsageSnapshot? = nil
    @Published var lastPollResult: ParseResult? = nil
    @Published var isLoading = false
    @Published var lastError: String? = nil
    @Published var lastPolledAt: Date? = nil
    @Published var isPopoverOpen = false

    let pipeline: SnapshotPipeline
    private var pollTask: Task<Void, Never>?
    private var backoffSeconds: Double = 0

    static let activeInterval: TimeInterval = 15
    static let backgroundInterval: TimeInterval = 60
    static let staleThreshold: TimeInterval = 180

    init() {
        let cliPath = CLIPathDetector.detect() ?? "/usr/local/bin/claude"
        let runner = ProcessCommandRunner(config: RunnerConfig(cliPath: cliPath))
        let store = (try? SnapshotStore.applicationSupport())
            ?? SnapshotStore(directory: FileManager.default.temporaryDirectory)
        self.pipeline = SnapshotPipeline(runner: runner, parser: ClaudeOutputParser(cliPath: cliPath), store: store)
        self.snapshot = try? store.readLatest()
        self.lastPolledAt = snapshot?.lastSuccessfulPollAt
        if snapshot == nil, let record = try? store.readLastError() {
            self.lastError = record.message
        }
        startPolling()
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
                let interval = self.isPopoverOpen ? Self.activeInterval : Self.backgroundInterval
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
        return Date().timeIntervalSince(polledAt) > Self.staleThreshold
    }

    var severity: UsageSeverity {
        snapshot?.state.severity ?? .unknown
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

            if let snap = result.snapshot {
                snapshot = snap
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
}
