import Foundation
import MeterDomain
import MeterPlatform

/// What a slot's credential and identity say about its login now.
enum LoginRead: Sendable {
    case signedIn(ClaudeCredential, owner: AccountOwner, identity: LocalIdentity?)
    /// The credential was read, but its identity file could not be read now, so the owner is
    /// unknown. Such a read proves nothing, and no request goes out with it.
    case ownerUnknown(ClaudeCredential)
    case failed(AccountFailure, status: OwnerStatus)

    var status: OwnerStatus {
        switch self {
        case .signedIn(_, let owner, _): .signedIn(owner)
        case .ownerUnknown: .unknown
        case .failed(_, let status): status
        }
    }
}

/// Reads a slot's credential and identity. The owner is the identity from `.claude.json`
/// when it names an account, otherwise a digest of the access token. An identity file that
/// cannot be read now makes the owner unknown, never a different owner.
struct LoginReader: Sendable {
    let keychain: ClaudeCodeKeychain
    let fileTimeout: Duration

    /// Throws only `CancellationError`.
    func read(_ slot: LoginSlot) async throws -> LoginRead {
        switch try await keychain.credential(services: slot.services) {
        case .missing:
            return .failed(.credentialsMissing, status: .signedOut)
        case .invalid:
            return .failed(.credentialsInvalid, status: .unknown)
        case .unavailable:
            return .failed(.credentialsUnavailable, status: .unknown)
        case .found(let credential):
            let digest = AccountOwner.credential(Digest.sha256(credential.accessToken))
            switch try await identity(slot.identityFile) {
            case .found(let identity):
                return .signedIn(credential, owner: identity.owner ?? digest, identity: identity)
            case .absent:
                return .signedIn(credential, owner: digest, identity: nil)
            case .unreadable:
                return .ownerUnknown(credential)
            }
        }
    }

    /// The identity in `file`. A read that times out, or finds the pool of blocking reads
    /// full, is unreadable. Throws only `CancellationError`.
    func identity(_ file: URL?, timeout: Duration? = nil) async throws -> LocalIdentity.Read {
        guard let file else { return .absent }
        do {
            return try await BlockingIO.run(timeout: timeout ?? fileTimeout) { cancellation in
                LocalIdentity.read(file, cancellation: cancellation)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
    }
}
