import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import MeterApp

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
