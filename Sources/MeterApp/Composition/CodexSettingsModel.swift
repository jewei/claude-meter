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
        /// The canonical folder, with links resolved.
        public let path: String
        /// The default name: "Codex" for the implicit home, else the folder name.
        public let defaultName: String
        /// The implicit home cannot be removed.
        public let isImplicit: Bool
        public var status: SignInStatus?
        /// The texts in `CodexSettings.extraHomes` whose canonical path is this home, as of the
        /// last reload. Add saves the canonical path, but a folder that moved and left a link
        /// at its old path is still saved by the link, and more than one text can name the
        /// same home. Remove deletes all of them. Rename and Remove act only while one of them
        /// is still saved; rename also acts on the implicit home, which Remove never removes.
        /// Empty when no saved text names the home; the implicit home has one only when its
        /// path is also saved as an added home.
        public let savedPaths: [String]

        init(
            id: AccountID, path: String, defaultName: String, isImplicit: Bool,
            status: SignInStatus?, savedPaths: [String] = []
        ) {
            self.id = id
            self.path = path
            self.defaultName = defaultName
            self.isImplicit = isImplicit
            self.status = status
            self.savedPaths = savedPaths
        }
    }

    /// Reads the Codex homes of a configuration: the implicit home first, then the added ones.
    typealias HomeReader = @Sendable (CodexConfiguration) async throws -> [CodexHome]

    /// The longest wait for a folder check: a home that the user adds, or the saved homes that
    /// a reload matches with the list.
    static let folderCheckLimit: Duration = .seconds(5)

    public private(set) var homes: [Home] = []
    public private(set) var isLoading = false
    /// The last failed add, for the user.
    public private(set) var error: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let provider: CodexProvider
    @ObservationIgnored private let readHomes: HomeReader
    /// Each reload gets a number; an older reload never writes over a newer one.
    @ObservationIgnored private var generation = 0

    /// - Parameter readHomes: Reads the homes. Defaults to the provider's
    ///   `resolveHomes(for:)`; tests replace it to hold a read.
    init(settings: SettingsStore, provider: CodexProvider, readHomes: HomeReader? = nil) {
        self.settings = settings
        self.provider = provider
        self.readHomes = readHomes ?? { try await provider.resolveHomes(for: $0) }
    }

    /// Reads the homes and their sign-in status again. A home keeps its last status until its
    /// new check finishes, so the list does not flicker. A reload that a newer one overtook
    /// stops without writing.
    public func reload() async {
        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        let configuration = settings.codexConfiguration
        let saved = settings.settings.codex.extraHomes
        // A slow disk keeps the current list rather than showing no homes.
        guard let resolved = try? await readHomes(configuration),
            let canonical = try? await Self.canonicalPaths(of: saved),
            current == generation
        else { return }
        let earlier = Dictionary(
            homes.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        homes = resolved.map { home in
            Home(
                id: home.id, path: home.directory.path, defaultName: home.name,
                isImplicit: home.isImplicit, status: earlier[home.id] ?? nil,
                savedPaths: saved.filter { canonical[$0] == home.directory.path })
        }
        for (index, home) in resolved.enumerated() {
            let status = await provider.signInStatus(for: home)
            guard current == generation else { return }
            homes[index].status = status
        }
    }

    /// Adds a folder that holds `auth.json` or `config.toml`. Returns false and sets
    /// ``error`` when the folder is not a Codex home, is already a home (the implicit one
    /// included), or the folder or the homes do not answer within 5 s.
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
                "That folder does not look like a Codex config dir. "
                + "Choose a folder with auth.json or config.toml."
            return false
        }
        // ``homes`` is empty before the first reload and old after one that timed out, so
        // compare with the homes as they are now. Otherwise the implicit home could be saved
        // again as a hidden extra home.
        let current: [CodexHome]
        do {
            current = try await readHomes(settings.codexConfiguration)
        } catch {
            self.error = "Could not check the Codex config dirs in time. Try again."
            return false
        }
        guard !current.contains(where: { $0.directory.path == canonical.path }),
            !settings.settings.codex.extraHomes.contains(canonical.path)
        else {
            error = "That config dir is already listed."
            return false
        }
        error = nil
        settings.update { $0.codex.extraHomes.append(canonical.path) }
        return true
    }

    /// Removes a listed home that the user added, with its name, pin, and card state. The
    /// implicit home is never removed, also when its path is saved as an added home too.
    public func removeHome(_ id: AccountID) {
        guard let home = listedHome(id), !home.isImplicit else { return }
        settings.update { settings in
            settings.codex.extraHomes.removeAll { home.savedPaths.contains($0) }
            settings.forgetAccount(id, of: .codex)
        }
    }

    /// Stores the trimmed name of a listed home. A blank name removes it. A home that is not
    /// listed gets no name, so a name edit that ends after its home was removed does not
    /// come back.
    public func rename(_ id: AccountID, to name: String) {
        guard listedHome(id) != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.codex.accountNames[id] = trimmed.isEmpty ? nil : trimmed }
    }

    /// The home that Settings lists for `id`: on the list, and still saved when the user
    /// added it.
    private func listedHome(_ id: AccountID) -> Home? {
        guard let home = homes.first(where: { $0.id == id }) else { return nil }
        let saved = settings.settings.codex.extraHomes
        let isSaved = home.isImplicit || home.savedPaths.contains(where: saved.contains)
        return isSaved ? home : nil
    }

    /// The canonical path of each saved home text, made the same way as the provider makes a
    /// home's ID. Resolving links can block on a stuck volume, so the wait has a limit.
    private static func canonicalPaths(of saved: [String]) async throws -> [String: String] {
        guard !saved.isEmpty else { return [:] }
        return try await BlockingIO.run(timeout: folderCheckLimit) { _ in
            var canonical: [String: String] = [:]
            for path in saved {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                canonical[path] = url.resolvingSymlinksInPath().path
            }
            return canonical
        }
    }
}
