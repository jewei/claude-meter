import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import ProviderCodex
import Testing

@testable import MeterApp

@MainActor
@Suite(.timeLimit(.minutes(1))) final class CodexSettingsModelTests {
    private let home: TemporaryDirectory
    private let implicit: URL
    private let settings = SettingsStore(store: MemoryStore())
    private let provider: CodexProvider
    private let model: CodexSettingsModel

    init() throws {
        home = try TemporaryDirectory()
        implicit = try home.makeDirectory(".codex")
        let settings = settings
        provider = CodexProvider(
            configuration: { @MainActor in settings.codexConfiguration },
            http: FakeHTTPClient(status: 500, json: "{}"),
            environment: ["CODEX_HOME": implicit.path, "PATH": ""], home: home.url)
        model = CodexSettingsModel(settings: settings, provider: provider)
    }

    deinit {
        home.remove()
    }

    private var implicitID: AccountID { AccountID(implicit.path) }

    private func makeHome(_ name: String) throws -> URL {
        try home.write("", to: "\(name)/config.toml").deletingLastPathComponent()
    }

    @Test func addHomeRejectsNonHomesAndDuplicates() async throws {
        let empty = try home.makeDirectory("empty")
        #expect(await !model.addHome(empty))
        #expect(model.error?.contains("auth.json or config.toml") == true)

        let work = try makeHome("work")
        #expect(await model.addHome(work))
        #expect(model.error == nil)
        #expect(settings.settings.codex.extraHomes == [work.path])
        #expect(await !model.addHome(work))
        #expect(model.error == "That Codex home is already listed.")
    }

    /// The list is empty before the first reload, so the check reads the homes again.
    @Test func addHomeRefusesTheImplicitHomeBeforeTheListLoads() async throws {
        try home.write("", to: ".codex/config.toml")
        let link = home.path("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: implicit)
        #expect(model.homes.isEmpty)
        #expect(await !model.addHome(implicit))
        #expect(model.error == "That Codex home is already listed.")
        #expect(await !model.addHome(link))
        #expect(settings.settings.codex.extraHomes.isEmpty)
    }

    @Test func addHomeFailsWhenTheHomesDoNotAnswer() async throws {
        let model = CodexSettingsModel(settings: settings, provider: provider) { _ in
            throw ProviderError("Could not read the Codex home folders in time. Refresh again.")
        }
        #expect(await !model.addHome(try makeHome("work")))
        #expect(model.error == "Could not check the Codex homes in time. Try again.")
        #expect(settings.settings.codex.extraHomes.isEmpty)
    }

    @Test func reloadListsTheImplicitHomeThenAddedHomes() async throws {
        let work = try makeHome("work")
        #expect(await model.addHome(work))
        await model.reload()
        #expect(model.homes.map(\.path) == [implicit.path, work.path])
        #expect(model.homes.map(\.isImplicit) == [true, false])
        #expect(model.homes.map(\.defaultName) == ["Codex", "work"])
        #expect(model.homes.allSatisfy { $0.status != nil })
        #expect(!model.isLoading)
    }

    /// The first reload reads the homes before a new home is saved and ends last. It must
    /// not write its older list over the newer one.
    @Test func newerReloadWins() async throws {
        let provider = provider
        let gate = Gate()
        let reads = Locked(0)
        let model = CodexSettingsModel(settings: settings, provider: provider) { configuration in
            let read = reads.withLock { count in
                count += 1
                return count
            }
            if read == 1 { await gate.wait() }
            return try await provider.resolveHomes(for: configuration)
        }
        let first = Task { await model.reload() }
        #expect(await gate.waitForArrivals())
        let work = try makeHome("work")
        settings.update { $0.codex.extraHomes = [work.path] }
        await model.reload()
        #expect(model.homes.map(\.path) == [implicit.path, work.path])
        gate.open()
        await first.value
        #expect(model.homes.map(\.path) == [implicit.path, work.path])
        #expect(!model.isLoading)
    }

    @Test func removeHomeClearsItsNamePinAndCardState() async throws {
        let work = try makeHome("work")
        #expect(await model.addHome(work))
        await model.reload()
        let id = AccountID(work.path)
        model.rename(id, to: "Work")
        #expect(settings.settings.codex.accountNames == [id: "Work"])
        settings.update {
            $0.menuBar.pinnedAccounts[.codex] = id
            $0.cards.order = [.account(.codex, id), .account(.claude, "claude")]
            $0.cards.expanded = [.account(.codex, id)]
        }
        model.removeHome(id)
        #expect(settings.settings.codex.extraHomes.isEmpty)
        #expect(settings.settings.codex.accountNames.isEmpty)
        #expect(settings.settings.menuBar.pinnedAccounts.isEmpty)
        #expect(settings.settings.cards.order == [.account(.claude, "claude")])
        #expect(settings.settings.cards.expanded.isEmpty)
    }

    /// A home whose folder moved and left a link at its old path is listed by the folder, but
    /// saved by the link. Rename and Remove must still find it, and Remove must remove every
    /// saved path of the home, so that it does not come back.
    @Test func renameAndRemoveFollowASavedPathThatBecameALink() async throws {
        let moved = try makeHome("moved")
        let link = home.path("work")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
        let id = AccountID(moved.path)

        settings.update { $0.codex.extraHomes = [link.path] }
        await model.reload()
        #expect(model.homes.map(\.id) == [implicitID, id])
        #expect(model.homes.map(\.savedPaths) == [[], [link.path]])
        model.rename(id, to: "Work")
        #expect(settings.settings.codex.accountNames == [id: "Work"])
        settings.update { $0.menuBar.pinnedAccounts[.codex] = id }
        model.removeHome(id)
        #expect(settings.settings.codex.extraHomes.isEmpty)
        #expect(settings.settings.codex.accountNames.isEmpty)
        #expect(settings.settings.menuBar.pinnedAccounts.isEmpty)

        // The link and the folder both saved: one home, and Remove removes both paths.
        settings.update { $0.codex.extraHomes = [link.path, moved.path] }
        await model.reload()
        #expect(model.homes.map(\.savedPaths) == [[], [link.path, moved.path]])
        model.removeHome(id)
        #expect(settings.settings.codex.extraHomes.isEmpty)
        await model.reload()
        #expect(model.homes.map(\.id) == [implicitID])
    }

    /// Also when an earlier version saved the implicit home's path as an added home.
    @Test func theImplicitHomeCannotBeRemoved() async {
        settings.update { $0.codex.extraHomes = [self.implicit.path] }
        await model.reload()
        #expect(model.homes.map(\.isImplicit) == [true])
        model.rename(implicitID, to: "Main")
        settings.update { $0.menuBar.pinnedAccounts[.codex] = self.implicitID }
        model.removeHome(implicitID)
        #expect(settings.settings.codex.accountNames == [implicitID: "Main"])
        #expect(settings.settings.menuBar.pinnedAccounts[.codex] == implicitID)
        #expect(settings.settings.codex.extraHomes == [implicit.path])
    }

    @Test func renameTrimsAndClears() async {
        await model.reload()
        model.rename(implicitID, to: "  Work  ")
        #expect(settings.settings.codex.accountNames == [implicitID: "Work"])
        model.rename(implicitID, to: " ")
        #expect(settings.settings.codex.accountNames.isEmpty)
    }

    /// A name edit that ends after its home was removed must not bring the name back.
    @Test func renameIgnoresHomesThatAreNotListed() async throws {
        model.rename("/h", to: "Nowhere")
        let work = try makeHome("work")
        #expect(await model.addHome(work))
        await model.reload()
        let id = AccountID(work.path)
        model.removeHome(id)
        model.rename(id, to: "Late")
        #expect(settings.settings.codex.accountNames.isEmpty)
    }
}
