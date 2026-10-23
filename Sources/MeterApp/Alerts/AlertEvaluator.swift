import Foundation
import MeterDomain

/// Decides which alerts are owed. Pure: the same context, kinds, and state give the same
/// alerts and state. `docs/product.md` §8 states the rules.
///
/// State lives per window, because provider jobs finish separately and a restored reading is
/// never fresh: one global "first evaluation" flag would alert for a window that the evaluator
/// never saw before.
struct AlertEvaluator {
    /// What the evaluator saw of one period of a window.
    struct Snapshot: Equatable, Sendable {
        var resetsAt: Date
        /// An observation of the period saw critical or exhausted severity, or a projected
        /// run-out. Only accumulates, so no later observation erases it.
        var hadTrouble: Bool
    }

    struct WindowState: Equatable, Sendable {
        var snapshot: Snapshot?
        var fired: Set<Alert.Kind> = []
        /// An owner change asks for a silent baseline at the next evaluation.
        var needsBaseline = false
    }

    struct AccountKey: Hashable, Sendable {
        let provider: ProviderID
        let account: AccountID
    }

    /// An alert kind that the person turned on during this run: each window of these
    /// providers alerts once when the condition is already met, which confirms that alerts
    /// work.
    struct Activation: Equatable, Sendable {
        var providers: Set<ProviderID>
        var consumed: Set<Alert.Key> = []
    }

    struct State: Equatable, Sendable {
        /// The owner of each account at its last evaluation. A stored nil is an owner.
        var owners: [AccountKey: AccountOwner?] = [:]
        var windows: [Alert.Key: WindowState] = [:]
        var activations: [Alert.Kind: Activation] = [:]

        /// `kind` was turned on. Each window of `providers` alerts once if its condition is
        /// already met at its next evaluation.
        mutating func activate(_ kind: Alert.Kind, providers: Set<ProviderID>) {
            activations[kind] = Activation(providers: providers)
        }

        /// `kind` was turned off: what is still pending is dropped.
        mutating func deactivate(_ kind: Alert.Kind) {
            activations[kind] = nil
        }

        func isPending(_ kind: Alert.Kind, _ key: Alert.Key) -> Bool {
            guard let activation = activations[kind] else { return false }
            return activation.providers.contains(key.provider)
                && !activation.consumed.contains(key)
        }
    }

    /// The low-energy alert re-arms when used percent drops this far below critical.
    static let hysteresis: Double = 5

    static func evaluate(
        _ context: PresentationContext, enabledKinds: Set<Alert.Kind>, previous: State
    ) -> (alerts: [Alert], state: State) {
        var state = previous
        var alerts: [Alert] = []
        for provider in ProviderID.allCases where !context.restored.contains(provider) {
            for account in context.observedAccounts(for: provider) where !account.isStale {
                guard let observedAt = account.observedAt else { continue }
                checkOwner(account, provider: provider, state: &state)
                for window in account.windows {
                    let key = Alert.Key(
                        provider: provider, account: account.id, window: window.id)
                    let observation = Observation(
                        window: window, account: account, observedAt: observedAt,
                        context: context)
                    alerts += evaluate(
                        observation, key: key, provider: provider, enabledKinds: enabledKinds,
                        context: context, state: &state)
                }
            }
        }
        return (alerts, state)
    }

    /// Step 0: an owner change cannot prove that the login stayed, so every window that the
    /// state holds for the account drops its period and fired flags and gets a silent
    /// baseline. A first evaluation only stores the owner.
    private static func checkOwner(
        _ account: AccountUsage, provider: ProviderID, state: inout State
    ) {
        let accountKey = AccountKey(provider: provider, account: account.id)
        defer { state.owners[accountKey] = .some(account.owner) }
        guard let stored = state.owners[accountKey], stored != account.owner else { return }
        for key in state.windows.keys
        where key.provider == provider && key.account == account.id {
            state.windows[key]?.snapshot = nil
            state.windows[key]?.fired = []
            state.windows[key]?.needsBaseline = true
        }
    }

    /// One fresh window, with what the steps derive from it.
    private struct Observation {
        let window: QuotaWindow
        let account: AccountUsage
        let observedAt: Date
        let severity: Severity
        let runOut: Date?

        init(
            window: QuotaWindow, account: AccountUsage, observedAt: Date,
            context: PresentationContext
        ) {
            self.window = window
            self.account = account
            self.observedAt = observedAt
            severity = window.severity(context.thresholds)
            if case .runsOut(let date)? = Pace.of(
                window, observedAt: observedAt, now: context.now)?.verdict
            {
                runOut = date
            } else {
                runOut = nil
            }
        }

        var isTroubled: Bool { severity >= .critical || runOut != nil }
    }

    // Steps 1 through 6 for one window.
    private static func evaluate(
        _ observation: Observation, key: Alert.Key, provider: ProviderID,
        enabledKinds: Set<Alert.Kind>, context: PresentationContext, state: inout State
    ) -> [Alert] {
        let window = observation.window
        let observedAt = observation.observedAt
        let isFirst = state.windows[key] == nil
        var current = state.windows[key] ?? WindowState()
        let snapshot = current.snapshot
        let resetsAt = window.resetsAt.flatMap { $0 > observedAt ? $0 : nil }

        // Step 1: a new period starts only after the known reset, with a later reset.
        let isTransition =
            snapshot.map { old in
                old.resetsAt <= observedAt && resetsAt.map { $0 > old.resetsAt } == true
            } ?? false
        let isInPeriod = snapshot.map { $0.resetsAt > observedAt && resetsAt != nil } ?? false

        // Step 2: a refill is owed for a binding window that had trouble in the old period.
        let refillOwed =
            isTransition && window.isBinding && observation.severity == .normal
            && snapshot?.hadTrouble == true

        // Step 3: re-arm.
        if isTransition { current.fired = [] }
        if let used = window.usedPercent,
            used < context.thresholds.critical - hysteresis,
            snapshot == nil || isInPeriod
        {
            current.fired.remove(.lowEnergy)
        }

        // Step 4: conditions. An expired window already shows as reset.
        let isExpired = window.resetsAt.map { $0 <= context.now } ?? false
        let isMet: [Alert.Kind: Bool] = [
            .lowEnergy: !isExpired && window.isBinding && observation.severity >= .critical,
            .runOut: !isExpired && window.duration != nil && observation.runOut != nil,
            .refill: !isExpired && refillOwed,
        ]

        // Step 5: fired flags and alerts.
        let isBaseline = isFirst || current.needsBaseline
        var owed: [Alert.Kind] = []
        for kind in Alert.Kind.allCases where enabledKinds.contains(kind) {
            let met = isMet[kind] ?? false
            if state.isPending(kind, key) {
                state.activations[kind]?.consumed.insert(key)
                if met {
                    current.fired.insert(kind)
                    owed.append(kind)
                } else {
                    current.fired.remove(kind)
                }
            } else if isBaseline {
                if met { current.fired.insert(kind) }
            } else if met, !current.fired.contains(kind) {
                current.fired.insert(kind)
                owed.append(kind)
            }
        }
        current.needsBaseline = false

        // Step 6: update the snapshot.
        if let resetsAt, isTransition || snapshot == nil {
            current.snapshot = Snapshot(resetsAt: resetsAt, hadTrouble: observation.isTroubled)
        } else if isInPeriod, let resetsAt {
            current.snapshot?.resetsAt = resetsAt
            current.snapshot?.hadTrouble = snapshot?.hadTrouble == true || observation.isTroubled
        }
        state.windows[key] = current

        return owed.map { kind in
            Alert(
                key: key, kind: kind, title: AlertText.title(kind),
                body: AlertText.body(
                    kind, window: window, account: observation.account, provider: provider,
                    runOut: observation.runOut, context: context))
        }
    }
}
