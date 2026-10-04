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
