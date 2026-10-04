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
/// call that already runs cannot be stopped.
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

    private let keychain: any Keychain
    private let timeout: Duration
    private let writes = DispatchQueue(
        label: "com.jewei.claudemeter.claude-oauth-writes", qos: .utility)
    /// The sequence of the newest write that ran or was abandoned.
    private let newestWrite = Locked<UInt64>(0)

    init(keychain: any Keychain, timeout: Duration) {
        self.keychain = keychain
        self.timeout = timeout
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

    func save(_ credential: ManualCredential, sequence: UInt64) async throws {
        let data = try JSONEncoder.meter.encode(credential)
        try await write(sequence: sequence) { keychain in
            try keychain.setPassword(data, service: Self.service, account: Self.account)
        }
    }

    func delete(sequence: UInt64) async throws {
        try await write(sequence: sequence) { keychain in
            try keychain.deletePassword(service: Self.service, account: Self.account)
        }
    }

    /// Runs `operation` on the write queue. The caller's cancellation does not stop it: a
    /// rotated refresh token must be stored even when the refresh that got it was cancelled.
    private func write(
        sequence: UInt64, _ operation: @escaping @Sendable (any Keychain) throws -> Void
    ) async throws {
        let keychain = keychain
        let newestWrite = newestWrite
        let timeout = timeout
        try await withCheckedThrowingContinuation { continuation in
            let outcome = WriteOutcome(continuation)
            writes.async {
                // Claim the sequence; an older write, or one that was abandoned, is skipped.
                let isNewest = newestWrite.withLock { newest in
                    guard sequence > newest else { return false }
                    newest = sequence
                    return true
                }
                outcome.finish(isNewest ? Result { try operation(keychain) } : .success(()))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout.timeInterval
            ) {
                guard outcome.finish(.failure(TimeoutError(limit: timeout))) else { return }
                // The write has not started, or it hangs; either way it must not land later.
                newestWrite.withLock { $0 = max($0, sequence) }
            }
        }
    }

    /// Resumes a write's caller once, with the result or the timeout, whichever comes first.
    private final class WriteOutcome: Sendable {
        private let continuation: Locked<CheckedContinuation<Void, any Error>?>

        init(_ continuation: CheckedContinuation<Void, any Error>) {
            self.continuation = Locked(continuation)
        }

        /// Returns true when this call decided the outcome.
        @discardableResult
        func finish(_ result: Result<Void, any Error>) -> Bool {
            let waiting = continuation.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
            return waiting != nil
        }
    }
}
