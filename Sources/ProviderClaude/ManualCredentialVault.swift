import Foundation
import MeterDomain
import MeterPlatform

/// The app-owned Keychain item that holds the manual login. The only credential the app writes.
///
/// Writes carry a sequence number from ``ManualLogin``. A write applies only when it is newer
/// than every write before it, so a late save from an old refresh can never restore an item
/// that a disconnect deleted, even if the Keychain answers out of order.
final class ManualCredentialVault: Sendable {
    enum Read: Sendable, Equatable {
        case found(ManualCredential)
        case missing
        case invalid
        case unavailable(String)
    }

    static let service = "com.jewei.claudemeter.claude-oauth"
    static let account = "manual"

    private let keychain: any Keychain
    private let timeout: Duration
    /// The sequence of the newest write that was attempted.
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

    private func write(
        sequence: UInt64, _ operation: @escaping @Sendable (any Keychain) throws -> Void
    ) async throws {
        let keychain = keychain
        let newestWrite = newestWrite
        let outcome = try await BlockingIO.run(timeout: timeout) { _ in
            // The lock orders writes: an older write that runs late is skipped.
            newestWrite.withLock { newest -> Result<Void, any Error> in
                guard sequence > newest else { return .success(()) }
                newest = sequence
                return Result { try operation(keychain) }
            }
        }
        try outcome.get()
    }
}
