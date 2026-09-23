import Darwin
import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

private struct RecoveryHarness: Sendable {
    let directory: URL
    let executable: URL
    var pidsURL: URL { directory.appendingPathComponent("pids") }
    var requestsURL: URL { directory.appendingPathComponent("requests") }
    var pids: [pid_t] {
        let contents = (try? String(contentsOf: pidsURL, encoding: .utf8)) ?? ""
        return contents.split(separator: "\n").compactMap { pid_t($0) }
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("codex.sh")
        try #"""
        #!/bin/sh
        printf '%s\n' "$$" >> "$PIDS_FILE"
        while IFS= read -r request; do
          printf '%s\n' "$request" >> "$REQUESTS_FILE"
          case "$request" in
            *'"method":"initialize"'*) printf '{"id":1,"result":{}}\n' ;;
            *rateLimits*)
              case "$RECOVERY_BEHAVIOR" in
                failure) printf '{"id":3,"error":{"message":"quota unavailable"}}\n' ;;
                timeout) trap '' TERM; while :; do :; done ;;
                *) printf '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}\n' ;;
              esac ;;
            *account*read*)
              if [ "$RECOVERY_BEHAVIOR" = apikey ]; then
                printf '{"id":2,"result":{"account":{"type":"apiKey"}}}\n'
              else
                printf '{"id":2,"result":{"account":{"type":"chatgpt","planType":"plus"}}}\n'
              fi ;;
          esac
        done
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func source(_ behavior: String = "success") -> CodexAppServerSource {
        CodexAppServerSource(
            env: [
                "CODEX_HOME": directory.path, "PIDS_FILE": pidsURL.path,
                "REQUESTS_FILE": requestsURL.path, "RECOVERY_BEHAVIOR": behavior,
            ],
            startupTimeout: 5, requestTimeout: behavior == "timeout" ? 0.03 : 5,
            resolver: { _ in executable.path })
    }

    func assertReaped() {
        for pid in pids {
            errno = 0
            #expect(Darwin.kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor HomeUsageTransport: HTTPTransport {
    private var recoveredHome: String?
    private var offlineHome: String?
    private(set) var count = 0
    func recover(_ id: String?) { recoveredHome = id }
    func offline(_ id: String?) { offlineHome = id }
    func send(_ request: URLRequest, retry: HTTPRetryPolicy) async throws -> (Data, HTTPURLResponse)
    {
        count += 1
        let account = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
        if let offlineHome, account == offlineHome { throw URLError(.notConnectedToInternet) }
        let status = recoveredHome != nil && account == recoveredHome ? 401 : 200
        return (
            Data(#"{"rate_limit":{"primary_window":{"used_percent":12}}}"#.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Suite("Codex one-shot recovery", .timeLimit(.minutes(1)))
struct CodexOneShotTests {
    @Test("Each recovery launches once and reaps its child before returning")
    func successAndNoReuse() async throws {
        let harness = try RecoveryHarness()
        defer { harness.remove() }
        let source = harness.source()
        for count in 1...2 {
            let usage = try await source.fetchUsage()
            #expect(usage.source == .appServer)
            #expect(usage.primaryWindow?.usedPercent == 25)
            #expect(harness.pids.count == count)
            harness.assertReaped()
        }
        let requests = try String(contentsOf: harness.requestsURL, encoding: .utf8)
        #expect(requests.components(separatedBy: "\"refreshToken\":true").count == 3)
    }

    @Test(arguments: ["failure", "timeout", "apikey"])
    func failedRecoveryReapsChild(behavior: String) async throws {
        let harness = try RecoveryHarness()
        defer { harness.remove() }
        do {
            _ = try await harness.source(behavior).fetchUsage()
            Issue.record("Expected recovery failure")
        } catch {
            switch behavior {
            case "failure": #expect(error as? CodexUsageError == .rpcFailed("quota unavailable"))
            case "timeout":
                #expect(error as? CodexUsageError == .rpcTimedOut("account/rateLimits/read"))
            default: #expect(error as? CodexOAuthCredentialsError == .apiKeyOnly)
            }
        }
        #expect(harness.pids.count == 1)
        harness.assertReaped()
        if behavior == "apikey" {
            let requests = try String(contentsOf: harness.requestsURL, encoding: .utf8)
            #expect(!requests.contains("rateLimits"))
        }
    }

    @Test("Four healthy homes use direct HTTP; only auth recovery launches a child")
    @MainActor
    func multipleHomes() async throws {
        let harnesses = try (0..<4).map { _ in try RecoveryHarness() }
        defer { for harness in harnesses { harness.remove() } }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accounts = harnesses.enumerated().map { index, harness in
            CodexAccount(home: harness.directory, isImplicit: false, customName: "Home \(index)")
        }
        var originals: [Data] = []
        for (index, harness) in harnesses.enumerated() {
            let claims = #"{"sub":"member","chatgpt_account_id":"home-\#(index)","exp":1800003600}"#
            let token = "header.\(Data(claims.utf8).base64EncodedString()).signature"
            let auth = Data(
                #"{"tokens":{"access_token":"\#(token)","account_id":"home-\#(index)","refresh_token":"never-consume"}}"#
                    .utf8)
            try auth.write(to: harness.directory.appendingPathComponent("auth.json"))
            originals.append(auth)
        }
        let transport = HomeUsageTransport()
        let suite = "CodexOneShot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = Dictionary(uniqueKeysWithValues: zip(accounts.map(\.id), harnesses))
        let provider = CodexProviderAdapter(
            configuration: { CodexConfiguration(accounts: accounts) }, defaults: defaults,
            fetchAccount: { account, now in
                let recovery = sources[account.id]!.source()
                let direct = CodexDirectOAuthSource(
                    transport: transport,
                    credentialsLoader: {
                        try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": account.home.path])
                    })
                return try await CodexUsageProvider(appServerSource: recovery, oauthSource: direct)
                    .fetchUsage(now: now)
            })
        var previous: ProviderSnapshot?
        for cycle in 0..<3 {
            if cycle == 1 { await transport.recover("home-2") }
            if cycle == 2 {
                await transport.recover(nil)
                await transport.offline("home-1")
            }
            let id = UUID()
            let date = now.addingTimeInterval(Double(cycle) * 300)
            let valid = try await provider.validatePrevious(previous, now: date, refreshID: id)
            let snapshot = try await provider.fetch(now: date, previous: valid, refreshID: id)
            provider.didAccept(snapshot, refreshID: id)
            await provider.waitForPersistence()
            #expect(snapshot.accounts.map(\.id) == accounts.map(\.id))
            #expect(snapshot.accounts.allSatisfy { $0.observedAt != nil })
            if cycle == 2 {
                #expect(snapshot.accounts[1].isStale)
                #expect(snapshot.accounts[1].observedAt == previous?.accounts[1].observedAt)
            }
            for (index, harness) in harnesses.enumerated() {
                #expect(harness.pids.count == (cycle > 0 && index == 2 ? 1 : 0))
                harness.assertReaped()
                #expect(
                    try Data(contentsOf: harness.directory.appendingPathComponent("auth.json"))
                        == originals[index])
            }
            previous = snapshot
        }
        #expect(await transport.count == 12)
    }
}
