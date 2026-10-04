import Foundation
import MeterDomain
import MeterPlatform

extension AutomaticRefresh {
    /// What the Keychain says about Claude Code's active login.
    enum ActiveLogin: Sendable, Equatable {
        case service(String)
        /// Claude Code has no login.
        case none
        /// The Keychain could not answer now, for example while it is locked. Proves nothing.
        case unknown
    }

    struct Plan: Sendable, Equatable {
        /// Output order: an unmapped active login first, then config dirs in discovery order.
        var slots: [LoginSlot]
        /// The account of Claude Code's active login, or `claude` when there is none or it is
        /// unknown.
        var activeID: AccountID
        var activeLogin: ActiveLogin
        /// The key of every discovered config dir, enabled or not.
        var directoryIDs: Set<AccountID>

        /// The active login first, so that a 429 never starves the menu-bar account, then the
        /// others in output order.
        var requestOrder: [LoginSlot] {
            slots.filter { $0.id == activeID } + slots.filter { $0.id != activeID }
        }

        /// Whether an account without a slot can still belong to the active login. Only the
        /// active login gets an account that is not a config dir: an unmapped `oauth-…` key, or
        /// `claude` for the legacy item without `~/.claude`. While the Keychain cannot say which
        /// login is active, such an account keeps its value.
        func mayHoldActiveLogin(_ id: AccountID) -> Bool {
            guard activeLogin == .unknown, !directoryIDs.contains(id) else { return false }
            return id == ClaudeAccount.defaultID || id.rawValue.hasPrefix(LoginSlot.unmappedPrefix)
        }
    }

    /// Discovers config dirs and maps Claude Code's active Keychain item to one of them.
    func plan(_ configuration: ClaudeConfiguration) async throws -> Plan {
        let home = home
        let accounts: [ClaudeAccount]
        do {
            accounts = try await BlockingIO.run(timeout: limits.discovery) { _ in
                ConfigDirectoryScanner.discover(home: home, configuration: configuration)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError(
                "Could not read the Claude config folders. \(error.localizedDescription)")
        }
        let activeLogin: ActiveLogin
        do {
            activeLogin = try await keychain.activeService().map(ActiveLogin.service) ?? .none
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            activeLogin = .unknown
        }

        var slots = accounts.filter(\.isEnabled).map { LoginSlot(account: $0, home: home) }
        var activeID = ClaudeAccount.defaultID
        if case .service(let service) = activeLogin {
            // A disabled account can own the active login; it then has no slot and no card.
            if let owner = accounts.first(where: {
                ClaudeCodeKeychain.services(for: $0).contains(service)
            }) {
                activeID = owner.id
            } else if service == ClaudeCodeKeychain.legacyService {
                slots.insert(.legacyDefault(home: home), at: 0)
            } else {
                let unmapped = LoginSlot(unmappedService: service)
                slots.insert(unmapped, at: 0)
                activeID = unmapped.id
            }
        }
        return Plan(
            slots: slots, activeID: activeID, activeLogin: activeLogin,
            directoryIDs: Set(accounts.map(\.id)))
    }
}
