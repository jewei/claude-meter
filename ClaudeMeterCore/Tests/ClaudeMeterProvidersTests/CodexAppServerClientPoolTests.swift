import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

/// Covers the four rules that let one `codex app-server` process serve more than
/// one poll. The reuse is only as safe as these rules, so each has its own case.
@Suite("Codex app-server pool", .serialized)
struct CodexAppServerClientPoolTests {
    /// A fake app-server. It answers the three methods the source calls, appends
    /// one line per launch to `$LAUNCH_LOG`, and stays alive between requests so a
    /// pooled client has something to reuse.
    /// Order matters: `account/rateLimits/read` also contains `account`, so the
    /// rate-limit pattern has to be tested first. Keys are camel case because the
    /// source decodes with a plain `JSONDecoder`.
    private static let fakeScript = """
        #!/bin/sh
        printf 'launch\\n' >> "$LAUNCH_LOG"
        while IFS= read -r request; do
          id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$request" in
            *initialize*)
              printf '{"id":%s,"result":{}}\\n' "$id"
              if [ -n "$EXIT_AFTER_INITIALIZE" ]; then exit 0; fi
              ;;
            *rateLimits*)
              printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":40,"windowDurationMins":10080}}}}\\n' "$id"
              ;;
            *account*)
              printf '{"id":%s,"result":{"account":{"type":"chatgpt","planType":"pro"}}}\\n' "$id"
              ;;
          esac
        done
        """

    private struct Harness {
        let directory: URL
        let executable: URL
        let launchLog: URL
        let home: URL

        var launchCount: Int {
            guard let text = try? String(contentsOf: launchLog, encoding: .utf8) else { return 0 }
            return text.split(separator: "\n").count
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeHarness(exitAfterInitialize: Bool = false) throws -> Harness {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("codex-pool-\(UUID().uuidString)", isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-codex.sh")
        try Self.fakeScript.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return Harness(
            directory: directory,
            executable: executable,
            launchLog: directory.appendingPathComponent("launches.log"),
            home: home)
    }

    private func makeSource(
        _ harness: Harness, pool: CodexAppServerClientPool, exitAfterInitialize: Bool = false
    ) -> CodexAppServerSource {
        var env = [
            "LAUNCH_LOG": harness.launchLog.path,
            "CODEX_HOME": harness.home.path,
        ]
        if exitAfterInitialize { env["EXIT_AFTER_INITIALIZE"] = "1" }
        return CodexAppServerSource(
            env: env,
            startupTimeout: 10,
            requestTimeout: 10,
            resolver: { _ in harness.executable.path },
            pool: pool)
    }

    /// Writes an `auth.json` whose owner claims resolve to `owner`.
    private func writeCredentials(_ harness: Harness, owner: String) throws {
        let claims = #"{"chatgpt_account_id":"\#(owner)","organization_id":"org"}"#
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).signature"
        let json = #"{"tokens":{"id_token":"\#(token)","access_token":"\#(token)"}}"#
        try Data(json.utf8).write(to: harness.home.appendingPathComponent("auth.json"))
    }

    @Test("A second poll reuses the running process")
    func secondPollReusesTheProcess() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let pool = CodexAppServerClientPool()
        defer { Task { await pool.shutdownAll() } }
        try writeCredentials(harness, owner: "owner-a")
        let source = makeSource(harness, pool: pool)

        _ = try await source.fetchUsage(now: Date())
        _ = try await source.fetchUsage(now: Date())
        _ = try await source.fetchUsage(now: Date())

        #expect(await pool.launchCount == 1)
        #expect(harness.launchCount == 1)
    }

    @Test("Rule 1: a changed sign-in starts a new process")
    func changedCredentialIdentityRestarts() async throws {
        // The live process holds its sign-in in memory. Without this rule it can
        // answer with the previous account after the user signs in again.
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let pool = CodexAppServerClientPool()
        defer { Task { await pool.shutdownAll() } }
        try writeCredentials(harness, owner: "owner-a")
        let source = makeSource(harness, pool: pool)

        _ = try await source.fetchUsage(now: Date())
        #expect(await pool.launchCount == 1)

        try writeCredentials(harness, owner: "owner-b")
        _ = try await source.fetchUsage(now: Date())

        #expect(await pool.launchCount == 2)
    }

    @Test("Rule 2: an upgraded executable starts a new process")
    func changedExecutableRestarts() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let pool = CodexAppServerClientPool()
        defer { Task { await pool.shutdownAll() } }
        try writeCredentials(harness, owner: "owner-a")
        let source = makeSource(harness, pool: pool)

        _ = try await source.fetchUsage(now: Date())
        #expect(await pool.launchCount == 1)

        // Rewrite the same path, as a package upgrade does.
        try (Self.fakeScript + "\n# upgraded\n").write(
            to: harness.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: harness.executable.path)
        _ = try await source.fetchUsage(now: Date())

        #expect(await pool.launchCount == 2)
    }

    @Test("Rule 3: a process that exited is replaced")
    func deadProcessIsReplaced() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let pool = CodexAppServerClientPool()
        defer { Task { await pool.shutdownAll() } }
        try writeCredentials(harness, owner: "owner-a")
        let source = makeSource(harness, pool: pool)

        _ = try await source.fetchUsage(now: Date())
        #expect(await pool.launchCount == 1)

        await pool.killPooledProcessForTesting(home: harness.home.path)
        _ = try await source.fetchUsage(now: Date())

        #expect(await pool.launchCount == 2)
        #expect(harness.launchCount == 2)
    }

    @Test("Rule 4: a failed use is never reused")
    func failedUseIsDiscarded() async throws {
        // This fake exits during `initialize`, so the first fetch throws. The pool
        // must not keep that client.
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let pool = CodexAppServerClientPool()
        defer { Task { await pool.shutdownAll() } }
        try writeCredentials(harness, owner: "owner-a")
        let source = makeSource(harness, pool: pool, exitAfterInitialize: true)

        _ = try? await source.fetchUsage(now: Date())
        _ = try? await source.fetchUsage(now: Date())

        // Two attempts, two processes: nothing was carried over.
        #expect(await pool.launchCount == 2)
    }

    @Test("An idle client is shut down after the timeout")
    func idleClientIsEvicted() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let pool = CodexAppServerClientPool()
        defer { Task { await pool.shutdownAll() } }
        try writeCredentials(harness, owner: "owner-a")
        let source = makeSource(harness, pool: pool)

        _ = try await source.fetchUsage(now: Date())
        #expect(await pool.residentHomeCount == 1)

        await pool.evictIdleEntriesForTesting(
            now: Date().addingTimeInterval(CodexAppServerClientPool.idleTimeout + 1))

        #expect(await pool.residentHomeCount == 0)
    }
}
