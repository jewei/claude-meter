import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    @Suite struct CodexHomeTests {
        @Test func implicitHomeFirstThenExtrasCanonicalAndOnce() async throws {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let implicit = try root.makeDirectory("implicit")
            let work = try root.makeDirectory("work")
            try FileManager.default.createSymbolicLink(
                at: root.path("link-to-implicit"), withDestinationURL: implicit)
            let provider = CodexProvider(
                configuration: { CodexConfiguration() }, environment: ["CODEX_HOME": implicit.path],
                home: root.url, recovery: FakeRecovery())

            let homes = await provider.homes(
                for: CodexConfiguration(extraHomes: [
                    root.path("link-to-implicit"), work, root.url.appending(path: "work/../work"),
                ]))

            #expect(homes.map(\.directory.lastPathComponent) == ["implicit", "work"])
            #expect(homes.map(\.isImplicit) == [true, false])
            #expect(homes.map(\.name) == ["Codex", "work"])
            #expect(homes.first?.id == AccountID(implicit.resolvingSymlinksInPath().path))
        }

        @Test(arguments: [nil, "", "  "] as [String?])
        func withoutCodexHomeTheImplicitHomeIsDotCodex(variable: String?) {
            let user = URL(fileURLWithPath: "/tmp/someone", isDirectory: true)
            var environment: [String: String] = [:]
            environment["CODEX_HOME"] = variable
            let homes = CodexHome.resolve(extraHomes: [], environment: environment, userHome: user)
            #expect(homes.map(\.directory.lastPathComponent) == [".codex"])
            #expect(homes.first?.name == "Codex")
        }

        @Test func aHomeNeedsAnAuthFileOrAConfigFile() throws {
            let root = try TemporaryDirectory()
            defer { root.remove() }
            let empty = try root.makeDirectory("empty")
            #expect(!CodexProvider.looksLikeHome(empty))
            try root.write("model = \"o3\"", to: "config/config.toml")
            #expect(CodexProvider.looksLikeHome(root.path("config")))
            try root.write("{}", to: "auth/auth.json")
            #expect(CodexProvider.looksLikeHome(root.path("auth")))
        }
    }
}
