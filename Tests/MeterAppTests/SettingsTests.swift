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

    @Test func unknownCardIDDropsOnlyThatCard() {
        let data = Data(
            #"""
            {"cards": {"order": ["claude:work", "copilot:x", "extra-usage"],
                       "expanded": ["copilot:x", "grok:default"]}}
            """#.utf8)
        let settings = SettingsCodec.decode(data)
        #expect(settings.cards.order == [.account(.claude, "work"), .extraUsage])
        #expect(settings.cards.expanded == [.account(.grok, .default)])
    }

    @Test func unknownProviderPinKeepsTheMainProviderAndOtherPins() {
        let data = Data(
            #"""
            {"menuBar": {"provider": "codex",
                         "pinnedAccounts": {"codex": "/h", "copilot": "x"}}}
            """#.utf8)
        let settings = SettingsCodec.decode(data)
        #expect(settings.menuBar.provider == .codex)
        #expect(settings.menuBar.pinnedAccounts == [.codex: "/h"])
    }

    @Test func badDisplayNameKeepsTheClaudeConnection() {
        let data = Data(
            #"""
            {"claude": {"connection": "automatic", "accountNames": {"claude": 7, "claude-work": "Work"},
                        "extraDirectories": ["/a", 3]}}
            """#.utf8)
        let settings = SettingsCodec.decode(data)
        #expect(settings.claude.connection == .automatic)
        #expect(settings.claude.accountNames == ["claude-work": "Work"])
        #expect(settings.claude.extraDirectories == ["/a"])
    }

    @Test func unknownValueKeepsItsDefault() {
        let data = Data(
            #"{"menuBar": {"provider": "copilot", "pinnedAccounts": {"claude": "a"}}}"#.utf8)
        let settings = SettingsCodec.decode(data)
        #expect(settings.menuBar.provider == .claude)
        #expect(settings.menuBar.pinnedAccounts == [.claude: "a"])
    }

    @Test func thresholdsClampOnDecode() {
        let data = Data(
            #"{"appearance": {"thresholds": {"warning": 20, "critical": 200}}}"#.utf8)
        #expect(
            SettingsCodec.decode(data).appearance.thresholds
                == Thresholds(warning: 50, critical: 100))
        let wrong = Data(
            #"{"appearance": {"thresholds": {"warning": "high", "critical": 90}}}"#.utf8)
        #expect(
            SettingsCodec.decode(wrong).appearance.thresholds
                == Thresholds(warning: 80, critical: 90))
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

    /// One entry that does not decode (an unknown provider or window kind) is skipped; the
    /// other saved readings still load.
    @Test func aBadEntrySkipsOnlyThatProvider() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let claude = try JSONEncoder.meter.encode(ProviderUsage.sample(.claude))
        var codex = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder.meter.encode(ProviderUsage.sample(.codex)))
                as? [String: Any])
        var accounts = try #require(codex["accounts"] as? [[String: Any]])
        var windows = try #require(accounts[0]["windows"] as? [[String: Any]])
        windows[0]["kind"] = "hourly"
        accounts[0]["windows"] = windows
        codex["accounts"] = accounts
        let object: [String: Any] = [
            "claude": try JSONSerialization.jsonObject(with: claude),
            "codex": codex,
            "bard": try JSONSerialization.jsonObject(with: claude),
            // A value saved under the wrong key.
            "grok": try JSONSerialization.jsonObject(with: claude),
        ]
        let file = directory.path("readings.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let loaded = await ReadingArchive(file: file).load()
        #expect(loaded == [.claude: .sample(.claude)])
    }

    @Test func unreadableFilesLoadAsEmpty() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = try directory.write("{broken", to: "readings.json")
        #expect(await ReadingArchive(file: file).load().isEmpty)
        #expect(await ReadingArchive(file: directory.path("none.json")).load().isEmpty)
    }
}
