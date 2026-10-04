import Foundation
import MeterDomain
import MeterPlatform
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

    /// The longest wait for a folder check when the user adds a home.
    static let folderCheckLimit: Duration = .seconds(5)

    public private(set) var homes: [Home] = []
    public private(set) var isLoading = false
    /// The last failed add, for the user.
    public private(set) var error: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let provider: CodexProvider
    /// Each reload gets a number; an older reload never writes over a newer one.
    @ObservationIgnored private var generation = 0

    init(settings: SettingsStore, provider: CodexProvider) {
        self.settings = settings
        self.provider = provider
    }

    /// Reads the homes and their sign-in status again. A home keeps its last status until its
    /// new check finishes, so the list does not flicker. A reload that a newer one overtook
    /// stops without writing.
    public func reload() async {
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        let resolved = await provider.homes(for: settings.codexConfiguration)
        guard current == generation else { return }
        let earlier = Dictionary(
            homes.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        homes = resolved.map {
            Home(
                id: $0.id, path: $0.directory.path, defaultName: $0.name,
                isImplicit: $0.isImplicit, status: earlier[$0.id] ?? nil)
        }
        for (index, home) in resolved.enumerated() {
            let status = await provider.signInStatus(for: home)
            guard current == generation else { return }
            homes[index].status = status
        }
    }

    /// Adds a folder that holds `auth.json` or `config.toml`. Returns false and sets
    /// ``error`` when the folder is not a Codex home, is already listed, or does not answer
    /// within 5 s.
    @discardableResult
    public func addHome(_ url: URL) async -> Bool {
        let checked: URL?
        do {
            // Resolving links and reading the folder can block on a stuck volume.
            checked = try await BlockingIO.run(timeout: Self.folderCheckLimit) { _ in
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                return CodexProvider.looksLikeHome(canonical) ? canonical : nil
            }
        } catch {
            self.error = "That folder did not respond. Try again."
            return false
        }
        guard let canonical = checked else {
            error =
                "That folder does not look like a Codex home. "
                + "Choose a folder with auth.json or config.toml."
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

    /// Removes a home that the user added, with its name, pin, and card state. The implicit
    /// home cannot be removed.
    public func removeHome(_ id: AccountID) {
        guard settings.settings.codex.extraHomes.contains(id.rawValue) else { return }
        settings.update { settings in
            settings.codex.extraHomes.removeAll { $0 == id.rawValue }
            settings.forgetAccount(id, of: .codex)
        }
    }

    /// Stores the trimmed name. A blank name removes it.
    public func rename(_ id: AccountID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.codex.accountNames[id] = trimmed.isEmpty ? nil : trimmed }
    }
}
