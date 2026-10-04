import Foundation
import MeterDomain
import Observation
import ProviderCodex

/// The Codex homes list in Settings > Data.
@MainActor @Observable
public final class CodexSettingsModel {
    public struct Home: Identifiable, Equatable, Sendable {
        public let id: AccountID
        public let path: String
        /// The default name: "Codex" for the implicit home, else the folder name.
        public let defaultName: String
        /// The implicit home cannot be removed.
        public let isImplicit: Bool
        public var status: SignInStatus?
    }

    public private(set) var homes: [Home] = []
    public private(set) var isLoading = false
    /// The last failed add, for the user.
    public private(set) var error: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let provider: CodexProvider

    init(settings: SettingsStore, provider: CodexProvider) {
        self.settings = settings
        self.provider = provider
    }

    /// Reads the homes and their sign-in status again.
    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        let resolved = await provider.homes(for: settings.codexConfiguration)
        var homes = resolved.map {
            Home(
                id: $0.id, path: $0.directory.path, defaultName: $0.name, isImplicit: $0.isImplicit)
        }
        self.homes = homes
        for (index, home) in resolved.enumerated() {
            homes[index].status = await provider.signInStatus(for: home)
        }
        self.homes = homes
    }

    /// Adds a folder that holds `auth.json` or `config.toml`. Returns false and sets
    /// ``error`` when the folder is not a Codex home or is already listed.
    @discardableResult
    public func addHome(_ url: URL) -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard CodexProvider.looksLikeHome(canonical) else {
            error = "That folder does not look like a Codex home. Choose a folder with auth.json."
            return false
        }
        guard !homes.contains(where: { $0.path == canonical.path }),
            !settings.settings.codex.extraHomes.contains(canonical.path)
        else {
            error = "That Codex home is already listed."
            return false
        }
        error = nil
        settings.update { $0.codex.extraHomes.append(canonical.path) }
        return true
    }

    public func removeHome(_ id: AccountID) {
        settings.update { settings in
            settings.codex.extraHomes.removeAll { $0 == id.rawValue }
            settings.codex.accountNames[id] = nil
        }
    }

    public func rename(_ id: AccountID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.codex.accountNames[id] = trimmed.isEmpty ? nil : name }
    }
}
