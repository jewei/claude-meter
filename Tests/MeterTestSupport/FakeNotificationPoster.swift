import MeterPlatform

/// A ``NotificationPosting`` that records posts. A gate holds a call to test time limits.
public final class FakeNotificationPoster: NotificationPosting {
    private struct State: Sendable {
        var authorization: NotificationAuthorization
        var grantsRequest = true
        var acceptsPosts = true
        var posted: [LocalNotification] = []
        var attempts: [LocalNotification] = []
        var requests = 0
        var heldRead: Gate?
    }

    private let state: Locked<State>
    /// When set, ``authorization()`` waits for it.
    public let authorizationGate: Gate?
    /// When set, ``post(_:)`` waits for it.
    public let postGate: Gate?
    /// When set, ``requestAuthorization()`` waits for it.
    public let requestGate: Gate?

    public init(
        authorization: NotificationAuthorization = .authorized, authorizationGate: Gate? = nil,
        postGate: Gate? = nil, requestGate: Gate? = nil
    ) {
        state = Locked(State(authorization: authorization))
        self.authorizationGate = authorizationGate
        self.postGate = postGate
        self.requestGate = requestGate
    }

    /// Notifications that macOS accepted.
    public var posted: [LocalNotification] { state.value.posted }
    /// Every post, accepted or not.
    public var attempts: [LocalNotification] { state.value.attempts }
    public var requests: Int { state.value.requests }

    public func setAuthorization(_ value: NotificationAuthorization) {
        state.withLock { $0.authorization = value }
    }

    /// Whether the next permission request is granted.
    public func setGrantsRequest(_ value: Bool) {
        state.withLock { $0.grantsRequest = value }
    }

    public func setAcceptsPosts(_ value: Bool) {
        state.withLock { $0.acceptsPosts = value }
    }

    /// The next ``authorization()`` reads the value at once, then waits for `gate` before it
    /// answers, like a read that macOS answers late.
    public func holdNextAuthorization(_ gate: Gate) {
        state.withLock { $0.heldRead = gate }
    }

    public func authorization() async -> NotificationAuthorization {
        let (value, held) = state.withLock { state in
            defer { state.heldRead = nil }
            return (state.authorization, state.heldRead)
        }
        if let held {
            await held.wait()
            return value
        }
        await authorizationGate?.wait()
        return state.value.authorization
    }

    public func requestAuthorization() async -> Bool {
        state.withLock { $0.requests += 1 }
        await requestGate?.wait()
        return state.withLock { state in
            guard state.authorization == .notDetermined else {
                return state.authorization == .authorized
            }
            state.authorization = state.grantsRequest ? .authorized : .denied
            return state.grantsRequest
        }
    }

    public func post(_ notification: LocalNotification) async -> Bool {
        state.withLock { $0.attempts.append(notification) }
        await postGate?.wait()
        return state.withLock { state in
            guard state.acceptsPosts else { return false }
            state.posted.append(notification)
            return true
        }
    }
}
