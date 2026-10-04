import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp
@testable import ProviderClaude

/// The config dirs of the Claude settings: listing, adding, removing, names, and plans.
@MainActor
@Suite(.timeLimit(.minutes(1))) final class ClaudeSettingsModelTests {
    private let fixture: ClaudeSettingsFixture

    init() throws {
        fixture = try ClaudeSettingsFixture()
    }

    private var model: ClaudeSettingsModel { fixture.model }
    private var settings: SettingsStore { fixture.settings }
    private var home: TemporaryDirectory { fixture.home }

    @Test func listsTheDefaultConfigDir() async {
        await model.reload()
        #expect(model.accounts.map(\.id) == ["claude"])
        #expect(model.accounts.first?.isRemovable == false)
        #expect(model.accounts.first?.defaultName == "Default")
        #expect(model.automaticStatus == .signedOut)
    }

    @Test func addsOnlyRealConfigDirsOnce() async throws {
        let empty = try home.makeDirectory("empty")
        #expect(await !model.addDirectory(empty))
        #expect(model.directoryMessage == "Choose a folder that holds settings.json or projects.")
        #expect(model.message == nil)

        let work = try home.write("{}", to: "work/settings.json").deletingLastPathComponent()
        #expect(await model.addDirectory(work))
        #expect(model.directoryMessage == nil)
        #expect(settings.settings.claude.extraDirectories == [work.path])
        #expect(await !model.addDirectory(work))
        #expect(model.directoryMessage == "That config dir is already listed.")
    }

    @Test func aFolderWithTheKeyOfAListedDirIsRefused() async throws {
        // `~/project/.claude` has the key `claude`, which `~/.claude` owns. Saved, it would
        // never be listed, so it could not be removed either.
        let project = try home.write("{}", to: "project/.claude/settings.json")
            .deletingLastPathComponent()

        #expect(await !model.addDirectory(project))

        // The listed dir is found by itself, so it cannot be removed.
        #expect(
            model.directoryMessage
                == "A config dir named claude is already listed. Choose a folder with another "
                + "name.")
        #expect(settings.settings.claude.extraDirectories.isEmpty)

        // A dir that the user added can be removed first.
        let team = try home.write("{}", to: "a/.claude-team/settings.json")
            .deletingLastPathComponent()
        let other = try home.write("{}", to: "b/.claude-team/settings.json")
            .deletingLastPathComponent()
        #expect(await model.addDirectory(team))
        #expect(await !model.addDirectory(other))
        #expect(
            model.directoryMessage
                == "A config dir named claude-team is already listed. Remove it first, then add "
                + "this folder.")
        #expect(settings.settings.claude.extraDirectories == [team.path])
    }

    @Test func theDefaultDirIsRefusedBeforeTheFirstReload() async {
        let defaultDir = home.path(".claude")
        #expect(await !model.addDirectory(defaultDir))
        #expect(model.directoryMessage == "That config dir is already listed.")
        #expect(settings.settings.claude.extraDirectories.isEmpty)
    }

    @Test func aSlowDiskKeepsTheListedConfigDirs() async throws {
        try home.write("{}", to: ".claude-work/settings.json")
        let isStuck = Locked(false)
        let settings = settings
        let provider = ClaudeProvider(
            configuration: { @MainActor in settings.claudeConfiguration },
            keychain: fixture.keychain, http: FakeHTTPClient { _ in .json(500, "{}") },
            store: MemoryStore(), home: home.url, now: Date.init, keychainUser: "alice",
            limits: ClaudeLimits(),
            scan: { home, configuration in
                // A listing that fails as one that runs out of time does.
                if isStuck.value { throw TimeoutError(limit: .seconds(5)) }
                return try ConfigDirectoryScanner.discover(home: home, configuration: configuration)
            })
        let model = ClaudeSettingsModel(
            settings: settings, usage: fixture.usage, provider: provider)
        await model.reload()
        #expect(model.accounts.map(\.id) == ["claude", "claude-work"])

        isStuck.withLock { $0 = true }
        await model.reload()

        #expect(model.accounts.map(\.id) == ["claude", "claude-work"])
        let other = try home.write("{}", to: "other/settings.json").deletingLastPathComponent()
        #expect(await !model.addDirectory(other))
        #expect(model.directoryMessage == "Could not list the config dirs. Try again.")
        #expect(settings.settings.claude.extraDirectories.isEmpty)
    }

    @Test func accountsFollowSettingsAndReadingsAtOnce() async throws {
        try home.write("{}", to: ".claude-work/settings.json")
        await model.reload()
        #expect(model.accounts.map(\.id) == ["claude", "claude-work"])
        model.setEnabled("claude-work", false)
        #expect(model.accounts.last?.isEnabled == false)
        model.setEnabled("claude-work", true)
        #expect(model.accounts.last?.isEnabled == true)

        #expect(model.accounts.last?.reportedPlan == nil)
        let reading = ProviderUsage(
            provider: .claude,
            accounts: [
                AccountUsage(id: "claude-work", name: "work", plan: "Max 5x", observedAt: Date())
            ])
        fixture.usage.restore([.claude: reading])
        #expect(model.accounts.last?.reportedPlan == "Max 5x")
    }

    @Test func aLoginWithoutAConfigDirIsListedToNameButNotToTurnOff() async {
        await model.reload()
        let reading = ProviderUsage(
            provider: .claude,
            accounts: [
                AccountUsage(id: "claude", name: "default", observedAt: Date()),
                AccountUsage(
                    id: "oauth-ab12cd34", name: "oauth-ab12cd34", plan: "Pro", observedAt: Date()),
            ])
        fixture.usage.restore([.claude: reading])

        #expect(model.accounts.map(\.id) == ["claude", "oauth-ab12cd34"])
        let unmapped = model.accounts[1]
        #expect(unmapped.path == nil)
        #expect(unmapped.reportedPlan == "Pro")
        #expect(!unmapped.canTurnOff)
        #expect(!unmapped.isRemovable)
        #expect(model.accounts[0].canTurnOff == false)
        model.rename("oauth-ab12cd34", to: "  Laptop ")
        #expect(settings.settings.claude.accountNames["oauth-ab12cd34"] == "Laptop")
    }

    @Test func removeDirectoryClearsNamePlanSwitchAndPin() async throws {
        let work = try home.write("{}", to: "work/settings.json").deletingLastPathComponent()
        #expect(await model.addDirectory(work))
        await model.reload()
        let id = try #require(model.accounts.first { $0.isRemovable }?.id)
        model.rename(id, to: "Day job")
        model.setPlanOverride(id, "Pro")
        model.setEnabled(id, false)
        settings.update {
            $0.menuBar.pinnedAccounts[.claude] = id
            $0.cards.expanded = [.account(.claude, id)]
        }
        model.removeDirectory(id)
        let claude = settings.settings.claude
        #expect(claude.extraDirectories.isEmpty)
        #expect(claude.accountNames.isEmpty)
        #expect(claude.planOverrides.isEmpty)
        #expect(claude.disabledAccounts.isEmpty)
        #expect(settings.settings.menuBar.pinnedAccounts.isEmpty)
        #expect(settings.settings.cards.expanded.isEmpty)

        // A name edit that ends after the removal cannot bring the account back.
        await model.reload()
        model.rename(id, to: "Day job")
        #expect(settings.settings.claude.accountNames.isEmpty)
    }

    @Test func aConfiguredDirListedThroughALinkCanBeRemoved() async throws {
        // The user added the real folder; later `~/.claude-work` became a link to it. Both
        // are one account, listed under the link.
        let real = try home.write("{}", to: "dotfiles/claude-work/settings.json")
            .deletingLastPathComponent()
        let canonical = try #require(await ClaudeProvider.configDirectory(at: real)).path
        settings.update { $0.claude.extraDirectories = [canonical] }
        try FileManager.default.createSymbolicLink(
            at: home.path(".claude-work"), withDestinationURL: real)
        await model.reload()
        let work = try #require(model.accounts.first { $0.id == "claude-work" })
        #expect(work.path?.hasSuffix("/.claude-work") == true)
        #expect(work.isRemovable)

        model.removeDirectory("claude-work")

        #expect(settings.settings.claude.extraDirectories.isEmpty)
    }

    @Test func theDefaultAccountCannotBeTurnedOffOrRemoved() async {
        model.setEnabled("claude", false)
        model.setEnabled("claude-work", false)
        #expect(settings.settings.claude.disabledAccounts == ["claude-work"])
        await model.reload()
        model.removeDirectory("claude")
        #expect(model.accounts.map(\.id) == ["claude"])
    }

    @Test func renameAndPlanStoreTrimmedText() async {
        await model.reload()
        model.rename("claude", to: "  Home  ")
        #expect(settings.settings.claude.accountNames["claude"] == "Home")
        model.rename("claude", to: "   ")
        #expect(settings.settings.claude.accountNames["claude"] == nil)
        model.rename("claude-gone", to: "Old")
        #expect(settings.settings.claude.accountNames.isEmpty)
        model.setPlanOverride("claude", " Pro ")
        #expect(settings.settings.claude.planOverrides["claude"] == "Pro")
        model.setPlanOverride("claude", nil)
        #expect(settings.settings.claude.planOverrides.isEmpty)
    }
}
