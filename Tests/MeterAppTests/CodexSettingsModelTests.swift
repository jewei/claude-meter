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
    private let settings = SettingsStore(store: MemoryStore())
    private let model: CodexSettingsModel

    init() throws {
        home = try TemporaryDirectory()
        let implicit = try home.makeDirectory(".codex")
        let settings = settings
        let provider = CodexProvider(
            configuration: { @MainActor in settings.codexConfiguration },
            http: FakeHTTPClient(status: 500, json: "{}"),
            environment: ["CODEX_HOME": implicit.path, "PATH": ""], home: home.url)
        model = CodexSettingsModel(settings: settings, provider: provider)
    }

    deinit {
        home.remove()
    }

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

    @Test func reloadListsTheImplicitHomeThenAddedHomes() async throws {
        let work = try makeHome("work")
        #expect(await model.addHome(work))
        await model.reload()
        #expect(model.homes.map(\.path) == [home.path(".codex").path, work.path])
        #expect(model.homes.map(\.isImplicit) == [true, false])
        #expect(model.homes.map(\.defaultName) == ["Codex", "work"])
        #expect(model.homes.allSatisfy { $0.status != nil })
        #expect(!model.isLoading)
    }

    @Test func newerReloadWins() async throws {
        async let first: Void = model.reload()
        let work = try makeHome("work")
        #expect(await model.addHome(work))
        async let second: Void = model.reload()
        _ = await (first, second)
        #expect(model.homes.map(\.path).last == work.path)
        #expect(!model.isLoading)
    }

    @Test func removeHomeClearsItsNamePinAndCardState() async throws {
        let work = try makeHome("work")
        #expect(await model.addHome(work))
        let id = AccountID(work.path)
        model.rename(id, to: "Work")
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

    @Test func theImplicitHomeCannotBeRemoved() {
        let id = AccountID(home.path(".codex").path)
        model.rename(id, to: "Main")
        model.removeHome(id)
        #expect(settings.settings.codex.accountNames == [id: "Main"])
    }

    @Test func renameTrimsAndClears() {
        model.rename("/h", to: "  Work  ")
        #expect(settings.settings.codex.accountNames == ["/h": "Work"])
        model.rename("/h", to: " ")
        #expect(settings.settings.codex.accountNames.isEmpty)
    }
}
