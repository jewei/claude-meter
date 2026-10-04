import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp

@Suite struct SettingsCodecTests {
    @Test func roundTripsEveryGroup() {
        var settings = Settings()
        settings.isPaused = true
        settings.claude.connection = .automatic
        settings.claude.accountNames = ["claude-work": "Work"]
        settings.codex.extraHomes = ["/tmp/codex"]
        settings.menuBar.pinnedAccounts = [.codex: "/tmp/codex"]
        settings.cards.order = [
            .account(.codex, "/tmp/codex"), .extraUsage, .account(.cursor, .default),
        ]
        settings.cards.expanded = [.account(.grok, .default)]
        settings.appearance.thresholds = Thresholds(warning: 70, critical: 90)
        #expect(SettingsCodec.decode(SettingsCodec.encode(settings)) == settings)
    }

    @Test func missingDataGivesDefaults() {
        #expect(SettingsCodec.decode(nil) == Settings())
        #expect(SettingsCodec.decode(Data("not json".utf8)) == Settings())
    }

    @Test func missingKeysTakeDefaults() {
        let data = Data(#"{"isPaused": true, "claude": {"connection": "manual"}}"#.utf8)
        let settings = SettingsCodec.decode(data)
        #expect(settings.isPaused)
        #expect(settings.claude.connection == .manual)
        #expect(settings.claude.isEnabled)
        #expect(settings.appearance == AppearanceSettings())
    }

    @Test func oneBadGroupDoesNotResetTheOthers() {
        let data = Data(#"{"isPaused": true, "appearance": {"cardStyle": "hexagons"}}"#.utf8)
        let settings = SettingsCodec.decode(data)
        #expect(settings.isPaused)
        #expect(settings.appearance == AppearanceSettings())
    }

    @Test func encodesDictionariesAsObjects() throws {
        var settings = Settings()
        settings.claude.accountNames = ["claude": "Home"]
        settings.menuBar.pinnedAccounts = [.claude: "claude"]
        let json = try #require(String(data: SettingsCodec.encode(settings), encoding: .utf8))
        #expect(json.contains(#""accountNames":{"claude":"Home"}"#))
        #expect(json.contains(#""pinnedAccounts":{"claude":"claude"}"#))
    }

    @Test func displayNamesIgnoreBlankOverrides() {
        var settings = Settings()
        settings.claude.accountNames = ["a": "  Work  ", "b": "   "]
        #expect(settings.displayName(for: .claude, account: "a") == "Work")
        #expect(settings.displayName(for: .claude, account: "b") == nil)
        #expect(settings.displayName(for: .cursor, account: "a") == nil)
    }

    @Test func cardIDsRoundTripAsText() {
        for id: CardID in [.account(.claude, "claude-work"), .account(.codex, "/a:b"), .extraUsage]
        {
            #expect(CardID(rawValue: id.rawValue) == id)
        }
        #expect(CardID(rawValue: "unknown:x") == nil)
        #expect(CardID(rawValue: "claude:") == nil)
        #expect(CardID.account(.cursor, .default).menuBarSelection == nil)
        #expect(CardID.account(.codex, "h").menuBarSelection?.provider == .codex)
    }
}

@MainActor
@Suite struct SettingsStoreTests {
    @Test func savesAndReportsChanges() {
        let defaults = MemoryStore()
        let store = SettingsStore(store: defaults)
        var changes: [(Settings, Settings)] = []
        store.onChange = { changes.append(($0, $1)) }
        store.update { $0.grok.isEnabled = true }
        #expect(changes.count == 1)
        #expect(SettingsStore(store: defaults).settings.grok.isEnabled)
    }

    @Test func unchangedValuesAreNotSaved() {
        let store = SettingsStore(store: MemoryStore())
        var count = 0
        store.onChange = { _, _ in count += 1 }
        store.update { $0.isPaused = false }
        #expect(count == 0)
    }
}

@Suite struct ReadingArchiveTests {
    @Test func savesOnlyIdentityOwnedObservations() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let archive = ReadingArchive(file: directory.path("readings.json"))
        var usage = ProviderUsage.sample(.claude, account: "claude")
        usage.accounts.append(
            AccountUsage(
                id: "secret", name: "s", observedAt: .reference(), owner: .credential("digest")))
        usage.accounts.append(.unavailable(id: "gone", name: "g", issue: UsageIssue("x")))
        archive.record(usage, for: .claude)
        archive.flush()

        let loaded = await ReadingArchive(file: archive.file).load()
        #expect(loaded[.claude]?.accounts.map(\.id) == ["claude"])
        let text = try String(contentsOf: archive.file, encoding: .utf8)
        #expect(!text.contains("digest"))
        let permissions = try FileManager.default.attributesOfItem(atPath: archive.file.path)[
            .posixPermissions]
        #expect(permissions as? Int == 0o600)
    }

    @Test func forgettingAProviderRemovesIt() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let archive = ReadingArchive(file: directory.path("readings.json"))
        archive.record(.sample(.claude), for: .claude)
        archive.record(.sample(.codex), for: .codex)
        archive.record(nil, for: .claude)
        archive.flush()
        let loaded = await ReadingArchive(file: archive.file).load()
        #expect(Set(loaded.keys) == [.codex])
    }

    @Test func forgetBeforeLoadStaysForgotten() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.path("readings.json")
        let earlier = ReadingArchive(file: file)
        earlier.record(.sample(.claude), for: .claude)
        earlier.flush()

        let archive = ReadingArchive(file: file)
        archive.record(nil, for: .claude)
        #expect(await archive.load().isEmpty)
        archive.record(.sample(.codex), for: .codex)
        archive.flush()
        #expect(Set(await ReadingArchive(file: file).load().keys) == [.codex])
    }

    @Test func recordBeforeLoadWins() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = directory.path("readings.json")
        let earlier = ReadingArchive(file: file)
        earlier.record(.sample(.claude, used: 10), for: .claude)
        earlier.flush()

        let archive = ReadingArchive(file: file)
        archive.record(.sample(.claude, used: 90), for: .claude)
        #expect(await archive.load().isEmpty)
        archive.flush()
        #expect(await ReadingArchive(file: file).load()[.claude] == .sample(.claude, used: 90))
    }

    @Test func anExistingFolderBecomesPrivate() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let folder = try directory.makeDirectory("ClaudeMeter")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let archive = ReadingArchive(file: folder.appending(path: "readings.json"))
        archive.record(.sample(.claude), for: .claude)
        archive.flush()
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[
            .posixPermissions]
        #expect(mode as? Int == 0o700)
    }

    @Test func unreadableFilesLoadAsEmpty() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = try directory.write("{broken", to: "readings.json")
        #expect(await ReadingArchive(file: file).load().isEmpty)
        #expect(await ReadingArchive(file: directory.path("none.json")).load().isEmpty)
    }
}
