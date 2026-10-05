import Dispatch
import Foundation
import MeterDomain
import MeterPlatform

/// The app-owned Keychain item that holds the manual login. The only credential the app writes.
///
/// Writes run one at a time on a private serial queue, in the order they were sent, and never
/// on the shared ``BlockingIO`` threads: a Keychain call that hangs holds one thread and delays
/// the later writes, but it cannot fill the pool that every provider uses. Each write carries a
/// sequence number from ``ManualLogin`` and runs only when it is newer than every write before
/// it. A write that times out before it starts is skipped, so it cannot land later. A Keychain
/// call that already runs cannot be stopped; ``queueRestore(_:sequence:)`` undoes one that may
/// still land.
final class ManualCredentialVault: Sendable {
    enum Read: Sendable, Equatable {
        case found(ManualCredential)
        case missing
        case invalid
        case unavailable(String)
    }

    /// `com.jewei.claudemeter.claude-oauth`; a development build uses its own item.
    static let service = AppIdentity.keychainService("claude-oauth")
    static let account = "manual"
    /// The manual login of Claude Meter 3, which version 4 never reads. It is the app's own
    /// item, so the app deletes it. Nil in a development build, which must never touch the
    /// items of an installed copy.
    static let version3Item: (service: String, account: String)? =
        AppIdentity.isDevelopmentBuild ? nil : ("com.jewei.claudemeter-oauth", "oauthManual")

    private let keychain: any Keychain
    /// The limit of a read.
    private let timeout: Duration
    /// The limit of a write.
    private let writeTimeout: Duration
    private let log = Log(.claude)
    private let writes = DispatchQueue(
        label: "com.jewei.claudemeter.claude-oauth-writes", qos: .utility)
    /// The sequence of the newest write that ran or was abandoned.
    private let newestWrite = Locked<UInt64>(0)
    private let timeLimit: TimeLimit

    /// Starts the time limit of one call on the write queue: `expire` runs after `limit`.
    typealias TimeLimit =
        @Sendable (_ limit: Duration, _ expire: @escaping @Sendable () -> Void) -> Void

    /// The time limit of the app: a timer on a global queue.
    static let realTime: TimeLimit = { limit, expire in
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + limit.timeInterval, execute: expire)
    }

    /// - Parameters:
    ///   - timeout: The limit of a read.
    ///   - writeTimeout: The limit of a write; `timeout` when nil.
    ///   - timeLimit: Starts the limit of each call on the write queue. A test can pass one
    ///     that ends a limit only when the test says, so load on the machine cannot end it.
    init(
        keychain: any Keychain, timeout: Duration, writeTimeout: Duration? = nil,
        timeLimit: @escaping TimeLimit = realTime
    ) {
        self.keychain = keychain
        self.timeout = timeout
        self.writeTimeout = writeTimeout ?? timeout
        self.timeLimit = timeLimit
    }

    /// Reads the item. Throws only `CancellationError`.
    func load() async throws -> Read {
        let keychain = keychain
        do {
            let data = try await BlockingIO.run(timeout: timeout) { _ in
                try keychain.password(service: Self.service, account: Self.account)
            }
            guard let data else { return .missing }
            guard let credential = try? JSONDecoder.meter.decode(ManualCredential.self, from: data),
                credential.isUsable
            else { return .invalid }
            return .found(credential)
        } catch is CancellationError {
            throw CancellationError()
        } catch KeychainError.denied {
            return .invalid
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// Whether the item exists. Reads attributes only.
    func signInStatus() async -> SignInStatus {
        let keychain = keychain
        do {
            let items = try await BlockingIO.run(timeout: timeout) { _ in
                try keychain.items(servicePrefix: Self.service, account: Self.account)
            }
            return items.contains { $0.service == Self.service } ? .signedIn : .signedOut
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// The item's value as stored, or nil when there is no item. It is read on the write
    /// queue, after every write sent before it, so a write-back of it undoes exactly the writes
    /// sent after it. Throws the Keychain error, or `TimeoutError` when the read does not end
    /// within the limit, for example behind a write that hangs. `timeout` replaces the
    /// vault's read limit.
    func storedValue(timeout: Duration? = nil) async throws -> Data? {
        let keychain = keychain
        return try await queued(timeout: timeout ?? self.timeout) {
            Result<Data?, any Error> {
                try keychain.password(service: Self.service, account: Self.account)
            }
        }
    }

    /// Writes `credential`. `timeout` replaces the vault's write limit for this write.
    func save(_ credential: ManualCredential, sequence: UInt64, timeout: Duration? = nil)
        async throws
    {
        let data = try JSONEncoder.meter.encode(credential)
        try await write(sequence: sequence, timeout: timeout ?? writeTimeout) { keychain in
            try keychain.setPassword(data, service: Self.service, account: Self.account)
        }
    }

    func delete(sequence: UInt64) async throws {
        try await write(sequence: sequence, timeout: writeTimeout) { keychain in
            try keychain.deletePassword(service: Self.service, account: Self.account)
        }
    }

    /// Writes back a value from ``storedValue()``, or deletes the item when it was nil.
    func restore(_ value: Data?, sequence: UInt64) async throws {
        try await write(sequence: sequence, timeout: writeTimeout) { keychain in
            try Self.restore(value, in: keychain)
        }
    }

    /// Writes back a value from ``storedValue()`` after every write sent before it, and returns
    /// at once. It has no deadline, so it is never skipped: when a save timed out while its
    /// Keychain call ran, that call may still land, and this write follows it. Only a failure
    /// of the Keychain is logged.
    func queueRestore(_ value: Data?, sequence: UInt64) {
        let keychain = keychain
        let newestWrite = newestWrite
        let log = log
        writes.async {
            // The queue keeps the order of the sequence numbers, so no newer write has run.
            // A newer write that timed out claimed its number, and is still skipped.
            newestWrite.withLock { $0 = max($0, sequence) }
            do {
                try Self.restore(value, in: keychain)
            } catch {
                log.error("Could not restore the manual Claude login after a failed save", error)
            }
        }
    }

    private static func restore(_ value: Data?, in keychain: any Keychain) throws {
        if let value {
            try keychain.setPassword(value, service: service, account: account)
        } else {
            try keychain.deletePassword(service: service, account: account)
        }
    }

    /// Deletes the version 3 item, so that no live refresh token stays behind after the
    /// upgrade. Deleting a missing item succeeds. Throws only `CancellationError`.
    func removeVersion3Item() async throws {
        guard let item = Self.version3Item else { return }
        let keychain = keychain
        do {
            try await BlockingIO.run(timeout: timeout) { _ in
                try keychain.deletePassword(service: item.service, account: item.account)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("Could not delete the Claude Meter 3 manual login", error)
        }
    }

    /// Runs `operation` on the write queue. The caller's cancellation does not stop it: a
    /// rotated refresh token must be stored even when the refresh that got it was cancelled.
    private func write(
        sequence: UInt64, timeout: Duration,
        _ operation: @escaping @Sendable (any Keychain) throws -> Void
    ) async throws {
        let keychain = keychain
        let newestWrite = newestWrite
        try await queued(timeout: timeout) {
            // Claim the sequence; an older write, or one that was abandoned, is skipped.
            let isNewest = newestWrite.withLock { newest in
                guard sequence > newest else { return false }
                newest = sequence
                return true
            }
            return isNewest ? Result { try operation(keychain) } : .success(())
        } onTimeout: {
            // Claim the sequence before the caller hears of the timeout, so a write that has
            // not started can never land after it. A write that already runs, or ended,
            // claimed it itself.
            newestWrite.withLock { $0 = max($0, sequence) }
        }
    }

    /// Runs `work` on the write queue and returns its result, or throws `TimeoutError` after
    /// `timeout`, whichever comes first. `onTimeout` runs before the caller hears of the
    /// timeout. Work that has not ended by then still runs; its result is dropped.
    private func queued<Value: Sendable>(
        timeout: Duration,
        _ work: @escaping @Sendable () -> Result<Value, any Error>,
        onTimeout: @escaping @Sendable () -> Void = {}
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let outcome = Outcome(continuation)
            // The limit starts first, so it covers the whole wait, and it has started when the
            // work starts.
            timeLimit(timeout) {
                onTimeout()
                outcome.finish(.failure(TimeoutError(limit: timeout)))
            }
            writes.async { outcome.finish(work()) }
        }
    }

    /// Resumes a caller once, with the result or the timeout, whichever comes first.
    private final class Outcome<Value: Sendable>: Sendable {
        private let continuation: Locked<CheckedContinuation<Value, any Error>?>

        init(_ continuation: CheckedContinuation<Value, any Error>) {
            self.continuation = Locked(continuation)
        }

        /// Returns true when this call decided the outcome.
        @discardableResult
        func finish(_ result: Result<Value, any Error>) -> Bool {
            let waiting = continuation.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
            return waiting != nil
        }
    }
}
