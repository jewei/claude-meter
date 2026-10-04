import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    @Suite struct ConfigDirectoryTests {
        @Test(arguments: [
            (".claude", "claude"),
            (".claude-it-oneone", "claude-it-oneone"),
            (".claude work!@#", "claudework"),
            ("。", "claude"),
            (".claude.bak", "claude.bak"),
        ])
        func accountKeysKeepTheStoredFormat(folder: String, key: String) {
            let url = URL(fileURLWithPath: "/x").appending(path: folder)
            #expect(ConfigDirectoryScanner.accountID(for: url) == AccountID(key))
        }

        @Test(arguments: [
            ("claude", "default"), ("claude-work", "work"), ("claude-", "claude-"),
            ("custom", "custom"),
        ])
        func labelsDropTheClaudePrefix(key: String, label: String) {
            #expect(ConfigDirectoryScanner.name(for: AccountID(key)) == label)
        }

        @Test func scanKeepsOnlyQualifyingDirsAndAlwaysTheDefault() throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            _ = try home.makeDirectory(".claude")
            try home.write("{}", to: ".claude-work/settings.json")
            _ = try home.makeDirectory(".claude-team/projects")
            _ = try home.makeDirectory(".claude-empty")
            try home.write("{}", to: ".config/settings.json")

            let accounts = ConfigDirectoryScanner.discover(
                home: home.url, configuration: ClaudeConfiguration(connection: .automatic))

            #expect(accounts.map(\.id) == ["claude", "claude-team", "claude-work"])
            #expect(accounts.map(\.name) == ["default", "team", "work"])
            #expect(accounts.map(\.isDefault) == [true, false, false])
            #expect(accounts.allSatisfy { $0.isEnabled && $0.issue == nil })
        }

        @Test func disabledAccountsAreListedButTheDefaultCannotBeDisabled() throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            _ = try home.makeDirectory(".claude")
            try home.write("{}", to: ".claude-work/settings.json")

            let configuration = ClaudeConfiguration(
                connection: .automatic, disabledAccounts: ["claude", "claude-work"])
            let accounts = ConfigDirectoryScanner.discover(
                home: home.url, configuration: configuration)

            #expect(configuration.disabledAccounts == ["claude-work"])
            #expect(accounts.map(\.id) == ["claude", "claude-work"])
            #expect(accounts.map(\.isEnabled) == [true, false])
        }

        @Test func configuredDuplicatesCollapseAndConfiguredPathsWinKeyCollisions() throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            _ = try home.makeDirectory(".claude")
            try home.write("{}", to: ".claude-work/settings.json")
            try home.write("{}", to: ".claude-team/settings.json")
            try home.write("{}", to: "elsewhere/.claude-work/settings.json")
            try home.write("{}", to: "custom/.claude-extra/settings.json")
            try FileManager.default.createSymbolicLink(
                at: home.path("alias"), withDestinationURL: home.path(".claude"))

            let configuration = ClaudeConfiguration(
                connection: .automatic,
                extraDirectories: [
                    home.path("elsewhere/.claude-work"), home.path("custom/.claude-extra"),
                    home.path("alias"), home.path(".claude-team"),
                ])
            let accounts = ConfigDirectoryScanner.discover(
                home: home.url, configuration: configuration)

            // The alias of ~/.claude collapses into the default account, a configured copy of a
            // scanned dir is one account, and a configured dir wins a key collision.
            #expect(accounts.map(\.id) == ["claude", "claude-extra", "claude-team", "claude-work"])
            let work = try #require(accounts.first { $0.id == "claude-work" })
            #expect(work.directory.path.hasSuffix("elsewhere/.claude-work"))
            #expect(accounts.allSatisfy { $0.issue == nil })
        }

        @Test func aConfiguredFolderThatIsNoLongerAConfigDirStaysListedWithAnIssue() throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            _ = try home.makeDirectory(".claude")
            _ = try home.makeDirectory("old/.claude-old")

            let configuration = ClaudeConfiguration(
                connection: .automatic,
                extraDirectories: [home.path("old/.claude-old"), home.path("gone/.claude-gone")])
            let accounts = ConfigDirectoryScanner.discover(
                home: home.url, configuration: configuration)

            #expect(accounts.map(\.id) == ["claude", "claude-gone", "claude-old"])
            #expect(accounts[0].issue == nil)
            #expect(
                accounts[1].issue?.message == "This folder no longer exists. Remove it in Settings."
            )
            #expect(accounts[2].issue?.message.contains("not a Claude config dir") == true)
            #expect(accounts[2].issue?.needsAction == true)
        }

        @Test func aBrokenConfiguredFolderNeverHidesAWorkingDirWithItsKey() throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            _ = try home.makeDirectory(".claude")
            try home.write("{}", to: ".claude-work/settings.json")
            _ = try home.makeDirectory("empty/.claude-work")

            let configuration = ClaudeConfiguration(
                connection: .automatic,
                extraDirectories: [home.path("usb/.claude-work"), home.path("empty/.claude-work")])
            let accounts = ConfigDirectoryScanner.discover(
                home: home.url, configuration: configuration)

            #expect(accounts.map(\.id) == ["claude", "claude-work"])
            let work = try #require(accounts.last)
            #expect(
                ConfigDirectoryScanner.canonicalPath(work.directory)
                    == ConfigDirectoryScanner.canonicalPath(home.path(".claude-work")))
            #expect(work.issue == nil)
        }

        @Test func aCandidateDroppedForItsKeyDoesNotClaimItsPath() throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            _ = try home.makeDirectory(".claude")
            try home.write("{}", to: ".claude-work/settings.json")
            try home.write("{}", to: "other/.claude-alias/settings.json")
            // `~/.claude-alias` is the work dir under another name.
            try FileManager.default.createSymbolicLink(
                at: home.path(".claude-alias"), withDestinationURL: home.path(".claude-work"))

            let configuration = ClaudeConfiguration(
                connection: .automatic, extraDirectories: [home.path("other/.claude-alias")])
            let accounts = ConfigDirectoryScanner.discover(
                home: home.url, configuration: configuration)

            // The configured dir takes the key `claude-alias`, so the link loses it; the work
            // dir behind the link is still found under its own key.
            #expect(accounts.map(\.id) == ["claude", "claude-alias", "claude-work"])
            #expect(accounts[1].directory.path.hasSuffix("other/.claude-alias"))
        }

        @Test func aConfigDirBehindALinkAlsoTriesTheServiceOfItsPathAsGiven() async throws {
            let harness = try ClaudeHarness()
            let main = try harness.directory(".claude", account: "acc-1")
            harness.signIn(main, token: "main", legacy: true)
            try harness.home.write("{}", to: "dotfiles/claude-work/settings.json")
            let linked = harness.home.path(".claude-work")
            try FileManager.default.createSymbolicLink(
                at: linked, withDestinationURL: harness.home.path("dotfiles/claude-work"))
            // Claude Code hashed the path without resolving the link.
            let asGiven =
                "Claude Code-credentials-"
                + ClaudeCodeKeychain.shortHash(linked.standardizedFileURL.path)
            #expect(asGiven != ClaudeCodeKeychain.hashedService(for: linked))
            harness.signIn(service: asGiven, token: "work", modifiedAt: .reference(-10))
            let http = usageServer(["main": "{}", "work": "{}"])

            let usage = try await harness.provider(http).fetch(previous: nil)

            #expect(usage.accounts.map(\.id) == ["claude", "claude-work"])
            #expect(usage.accounts[1].hasObservation)
            #expect(http.usageTokens == ["main", "work"])
        }

        @Test func theAsyncCheckReturnsTheCanonicalConfigDir() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let real = try home.write("{}", to: "real/.claude-work/settings.json")
                .deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(
                at: home.path("link"), withDestinationURL: real)
            _ = try home.makeDirectory("empty")

            let found = await ClaudeProvider.configDirectory(at: home.path("link"))
            #expect(found?.path == real.resolvingSymlinksInPath().path)
            #expect(await ClaudeProvider.configDirectory(at: home.path("empty")) == nil)
            #expect(await ClaudeProvider.configDirectory(at: home.path("missing")) == nil)
        }

        @Test func configDirectoryCheckNeedsSettingsOrProjects() async throws {
            let home = try TemporaryDirectory()
            defer { home.remove() }
            let empty = try home.makeDirectory("empty")
            let projects = try home.makeDirectory("withProjects/projects")
                .deletingLastPathComponent()
            let settings = try home.write("{}", to: "withSettings/settings.json")
                .deletingLastPathComponent()

            #expect(await ClaudeProvider.configDirectory(at: empty) == nil)
            #expect(await ClaudeProvider.configDirectory(at: projects) != nil)
            #expect(await ClaudeProvider.configDirectory(at: settings) != nil)
            #expect(await ClaudeProvider.configDirectory(at: home.path("missing")) == nil)
        }

        @Test func identityFileOfTheDefaultDirIsInTheHomeFolder() {
            let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
            #expect(
                LocalIdentity.file(for: home.appending(path: ".claude"), home: home).path
                    == "/Users/alice/.claude.json")
            #expect(
                LocalIdentity.file(for: home.appending(path: ".claude-work"), home: home).path
                    == "/Users/alice/.claude-work/.claude.json")
        }
    }
}
