import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    @Suite struct CodexProviderFetchTests {
        @Test func aDirectRequestNeedsNoRecovery() async throws {
            let bed = try CodexTestBed()
            defer { bed.remove() }
            let token = CodexFixtures.accessToken()
            try bed.writeAuth(CodexFixtures.authJSON(accessToken: token))
            let before = try Data(contentsOf: bed.root.path("home/auth.json"))

            let usage = try await bed.provider.fetch(previous: nil)

            let account = try #require(usage.accounts.first)
            #expect(usage.provider == .codex)
            #expect(usage.accounts.count == 1)
            #expect(account.id == (await bed.homes()).first?.id)
            #expect(account.name == "Codex")
            #expect(account.windows.map(\.usedPercent) == [9, 43])
            #expect(account.observedAt == .reference())
            #expect(account.issue == nil)
            #expect(
                account.owner
                    == .identity(Digest.sha256(parts: ["codex", "user-1", "workspace-1"])))
            #expect(bed.recovery.calls == 0)
            let request = try #require(bed.http.requests.first)
            #expect(bed.http.requests.count == 1)
            #expect(request.method == .get)
            #expect(request.url.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
            #expect(request.headers["Authorization"] == "Bearer \(token)")
            #expect(request.headers["ChatGPT-Account-Id"] == "workspace-1")
            #expect(request.headers["Accept"] == "application/json")
            #expect(request.headers["User-Agent"] == "ClaudeMeter")
            if case .never = request.retry {
            } else {
                Issue.record("The usage request must not retry")
            }
            #expect(try Data(contentsOf: bed.root.path("home/auth.json")) == before)
        }

        @Test func anEmptyAccountIDSendsNoAccountHeader() async throws {
            let bed = try CodexTestBed()
            defer { bed.remove() }
            try bed.writeAuth(CodexFixtures.authJSON(accountID: " "))
            _ = try await bed.provider.fetch(previous: nil)
            #expect(bed.http.requests.first?.headers["ChatGPT-Account-Id"] == nil)
        }

        enum CredentialProblem: String, CaseIterable {
            case missingFile, missingTokens, invalidJSON, directory, expiringToken
        }

        @Test(arguments: CredentialProblem.allCases)
        func credentialProblemsStartOneRecovery(problem: CredentialProblem) async throws {
            let recovery = FakeRecovery(rateLimits: CodexFixtures.rateLimits)
            let bed = try CodexTestBed(recovery: recovery)
            defer { bed.remove() }
            switch problem {
            case .missingFile: break
            case .missingTokens: try bed.writeAuth(#"{"auth_mode":"chatgpt"}"#)
            case .invalidJSON: try bed.writeAuth("{")
            case .directory: _ = try bed.root.makeDirectory("home/auth.json")
            case .expiringToken:
                let token = CodexFixtures.accessToken(expiresAt: .reference(60))
                try bed.writeAuth(CodexFixtures.authJSON(accessToken: token))
            }

            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)

            #expect(account.windows.map(\.usedPercent) == [22, 43])
            #expect(account.plan == "Pro 20X")
            #expect(recovery.calls == 1)
            #expect(bed.http.requests.isEmpty)
            #expect(
                recovery.environments.first?["CODEX_HOME"]
                    == (await bed.homes()).first?.directory.path)
        }

        @Test(arguments: [401, 403])
        func loginFailuresStartRecovery(status: Int) async throws {
            let recovery = FakeRecovery(rateLimits: CodexFixtures.rateLimits)
            let bed = try CodexTestBed(
                http: FakeHTTPClient(status: status, json: "{}"), recovery: recovery)
            defer { bed.remove() }
            try bed.writeAuth()
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(account.hasObservation)
            #expect(recovery.calls == 1)
        }

        @Test(arguments: [404, 429, 500, 502, 503])
        func otherStatusesDoNotStartRecovery(status: Int) async throws {
            let http = FakeHTTPClient(status: status, json: "{}", headers: ["Retry-After": "120"])
            let bed = try CodexTestBed(http: http)
            defer { bed.remove() }
            try bed.writeAuth()
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(!account.hasObservation)
            #expect(
                account.issue?.message
                    == "Codex usage request failed (HTTP \(status)). Refresh again later.")
            #expect(account.issue?.retryAt == Date.reference(120))
            #expect(account.attemptedAt == .reference())
            #expect(bed.recovery.calls == 0)
        }

        @Test func networkAndFormatFailuresDoNotStartRecovery() async throws {
            let offline = try CodexTestBed(http: FakeHTTPClient { _ in throw HTTPError.offline })
            defer { offline.remove() }
            try offline.writeAuth()
            let first = try await offline.provider.fetch(previous: nil).accounts.first
            #expect(first?.issue?.message.hasPrefix("Could not reach Codex.") == true)
            #expect(offline.recovery.calls == 0)

            let malformed = #"{"rate_limit":{"primary_window":{"used_percent":[]}}}"#
            let format = try CodexTestBed(http: FakeHTTPClient(json: malformed))
            defer { format.remove() }
            try format.writeAuth()
            let second = try await format.provider.fetch(previous: nil).accounts.first
            #expect(second?.issue?.message == CodexError.unexpectedResponse.localizedDescription)
            #expect(format.recovery.calls == 0)
        }

        @Test func aFailedRecoveryKeepsBothReasons() async throws {
            struct Boom: Error, LocalizedError {
                var errorDescription: String? {
                    "Codex CLI not found. Install Codex, then refresh."
                }
            }
            let bed = try CodexTestBed(recovery: FakeRecovery { _, _ in throw Boom() })
            defer { bed.remove() }
            try bed.writeAuth(#"{"auth_mode":"chatgpt"}"#)
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(
                account.issue?.message
                    == "Codex App Server failed: Codex CLI not found. Install Codex, then refresh. "
                    + "Direct OAuth failed: Codex auth file has no ChatGPT OAuth tokens. Run `codex login`."
            )
            #expect(account.issue?.needsAction == true)
        }

        @Test func apiKeyAuthNeverRequestsOrRecovers() async throws {
            let bed = try CodexTestBed()
            defer { bed.remove() }
            try bed.writeAuth(#"{"OPENAI_API_KEY":"sk-test"}"#)
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(account.issue?.message == CodexError.apiKeyOnly.localizedDescription)
            #expect(account.issue?.needsAction == true)
            #expect(bed.http.requests.isEmpty)
            #expect(bed.recovery.calls == 0)
        }

        @Test func anAPIKeyRecoveryIsNotCombined() async throws {
            let recovery = FakeRecovery(account: #"{"account":{"type":"apiKey"}}"#, rateLimits: nil)
            let bed = try CodexTestBed(recovery: recovery)
            defer { bed.remove() }
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(account.issue?.message == CodexError.apiKeyOnly.localizedDescription)
        }

        @Test func cancellationStopsTheFetch() async throws {
            let recovery = FakeRecovery { _, _ in
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
            let bed = try CodexTestBed(recovery: recovery)
            defer { bed.remove() }
            let provider = bed.provider
            let task = Task { try await provider.fetch(previous: nil) }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }

        @Test func signInStatusReadsOnlyTheAuthFile() async throws {
            let bed = try CodexTestBed()
            defer { bed.remove() }
            let home = try #require(await bed.homes().first)
            try bed.writeAuth()
            #expect(await bed.provider.signInStatus(for: home) == .signedIn)
            try bed.writeAuth(CodexFixtures.authJSON(mode: "apikey"))
            #expect(await bed.provider.signInStatus(for: home) == .signedOut)
            #expect(bed.http.requests.isEmpty)
        }

        @Test func diagnosticsDescribeTheLastAttempt() async throws {
            let bed = try CodexTestBed()
            defer { bed.remove() }
            #expect(await bed.provider.diagnostics().contains { $0.value == "None this launch" })
            try bed.writeAuth()
            _ = try await bed.provider.fetch(previous: nil)
            let facts = await bed.provider.diagnostics()
            #expect(facts.contains { $0.label == "Codex source" && $0.value == "Usage request" })
            #expect(facts.contains { $0.label == "Codex result" && $0.value == "Updated" })
            #expect(facts.contains { $0.label == "Codex CLI" })
        }
    }
}
