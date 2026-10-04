import Foundation
import MeterDomain
import MeterPlatform

/// A usage provider whose answers a test scripts one call at a time.
public final class FakeUsageProvider: UsageProvider {
    public typealias Fetch = @Sendable (ProviderUsage?) async throws -> ProviderUsage
    public typealias Reconcile = @Sendable (ProviderUsage?) async -> ProviderUsage?

    public let id: ProviderID
    private struct Script: Sendable {
        var queue: [Fetch] = []
        var last: Fetch?
    }

    private let script = Locked(Script())
    private let reconciler = Locked<Reconcile?>(nil)
    private let calls = Locked(0)

    public init(_ id: ProviderID) {
        self.id = id
    }

    /// Queues an answer. Fetches use queued answers in order; when none are left, the last
    /// answer repeats.
    public func enqueue(_ fetch: @escaping Fetch) {
        script.withLock { $0.queue.append(fetch) }
    }

    public func enqueue(_ usage: ProviderUsage) {
        enqueue { _ in usage }
    }

    public func enqueue(failure: ProviderError) {
        enqueue { _ in throw failure }
    }

    public func setReconcile(_ reconcile: @escaping Reconcile) {
        reconciler.withLock { $0 = reconcile }
    }

    public var fetchCount: Int { calls.value }

    public func reconcile(_ previous: ProviderUsage?) async -> ProviderUsage? {
        guard let reconcile = reconciler.value else { return previous }
        return await reconcile(previous)
    }

    public func fetch(previous: ProviderUsage?) async throws -> ProviderUsage {
        calls.withLock { $0 += 1 }
        let next = script.withLock { script -> Fetch? in
            if !script.queue.isEmpty { script.last = script.queue.removeFirst() }
            return script.last
        }
        guard let next else { throw ProviderError("No scripted answer.") }
        return try await next(previous)
    }
}

/// A token history provider whose answers a test scripts.
public final class FakeHistoryProvider: TokenHistoryProvider {
    public typealias Answer = @Sendable (Date) async throws -> ProviderTokenHistory

    public let id: ProviderID
    private let answer: Locked<Answer?>
    private let calls = Locked(0)

    public init(_ id: ProviderID, answer: Answer? = nil) {
        self.id = id
        self.answer = Locked(answer)
    }

    public func setAnswer(_ answer: @escaping Answer) {
        self.answer.withLock { $0 = answer }
    }

    public var callCount: Int { calls.value }

    public func history(now: Date) async throws -> ProviderTokenHistory {
        calls.withLock { $0 += 1 }
        guard let answer = answer.value else { throw ProviderError("No scripted history.") }
        return try await answer(now)
    }
}

extension ProviderUsage {
    /// One observed account with a single session window.
    public static func sample(
        _ provider: ProviderID, account: AccountID = .default, used: Double? = 40,
        observedAt: Date = .reference(), owner: AccountOwner? = .identity("owner")
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            accounts: [
                AccountUsage(
                    id: account, name: account.rawValue,
                    windows: [
                        QuotaWindow(
                            id: "session", title: "Session", kind: .session, usedPercent: used,
                            resetsAt: observedAt.addingTimeInterval(3_600))
                    ],
                    observedAt: observedAt, owner: owner)
            ])
    }
}
