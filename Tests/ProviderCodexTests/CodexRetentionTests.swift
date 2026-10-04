import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderCodex

extension CodexTests {
    /// Every retention path follows ``AccountUsage/belongs(to:)``.
    @Suite struct CodexRetentionTests {
        private static let rateLimits = CodexFixtures.value(CodexFixtures.rateLimits)

        private static func account(email: String) -> JSONValue? {
            CodexFixtures.value(
                CodexFixtures.json(["account": ["type": "chatgpt", "email": email]]))
        }

        /// A recovery that answers with `reply` until it is changed.
        private static func switchable(
            _ reply: CodexRecoveryReply
        ) -> (FakeRecovery, Locked<Result<CodexRecoveryReply, CodexError>>) {
            let next = Locked(Result<CodexRecoveryReply, CodexError>.success(reply))
            return (FakeRecovery { _, _ in try next.value.get() }, next)
        }

        /// CDX-02: a login without `auth.json` (keyring storage) is owned by the account that
        /// Codex reports, survives reconcile, and is dropped only when Codex says signed out.
        @Test func aKeyringLoginKeepsItsReadingUntilCodexSaysSignedOut() async throws {
            let (recovery, next) = Self.switchable(
                CodexRecoveryReply(
                    account: CodexFixtures.value(CodexFixtures.chatGPTAccount),
                    rateLimits: Self.rateLimits))
            let bed = try CodexTestBed(recovery: recovery)
            defer { bed.remove() }

            let first = try await bed.provider.fetch(previous: nil)
            #expect(first.accounts.first?.owner == CodexFixtures.keyringOwner)
            #expect(await bed.provider.reconcile(first) == first)

            next.withLock { $0 = .failure(.appServerTimedOut(step: "account/read")) }
            let second = try await bed.provider.fetch(previous: first)
            let kept = try #require(second.accounts.first)
            #expect(kept.isStale)
            #expect(kept.observedAt == first.accounts.first?.observedAt)

            let signedOut = CodexRecoveryReply(
                account: CodexFixtures.value(#"{"account":null,"requiresOpenaiAuth":true}"#),
                rateLimits: nil)
            next.withLock { $0 = .success(signedOut) }
            let third = try #require(try await bed.provider.fetch(previous: second).accounts.first)
            #expect(!third.hasObservation)
            #expect(third.issue?.message == CodexError.notSignedIn.localizedDescription)
            #expect(third.issue?.needsAction == true)
        }

        @Test func anotherKeyringAccountDropsTheReading() async throws {
            let (recovery, next) = Self.switchable(
                CodexRecoveryReply(
                    account: Self.account(email: "me@example.com"), rateLimits: Self.rateLimits))
            let bed = try CodexTestBed(recovery: recovery)
            defer { bed.remove() }
            let first = try await bed.provider.fetch(previous: nil)
            #expect(first.accounts.first?.hasObservation == true)

            // The rate limits fail, but account/read names a different account.
            next.withLock {
                $0 = .success(
                    CodexRecoveryReply(
                        account: Self.account(email: "other@example.com"),
                        rateLimits: CodexFixtures.value(#"{"other":{}}"#)))
            }
            let second = try #require(try await bed.provider.fetch(previous: first).accounts.first)
            #expect(!second.hasObservation)
        }

        /// Without a Codex CLI, no keyring login can exist, so a missing file is signed out.
        @Test func withoutACLIAMissingFileIsSignedOut() async throws {
            let (recovery, next) = Self.switchable(
                CodexRecoveryReply(
                    account: Self.account(email: "me@example.com"), rateLimits: Self.rateLimits))
            let bed = try CodexTestBed(recovery: recovery)
            defer { bed.remove() }
            let first = try await bed.provider.fetch(previous: nil)
            next.withLock { $0 = .failure(.cliNotFound) }
            let second = try #require(try await bed.provider.fetch(previous: first).accounts.first)
            #expect(!second.hasObservation)
            #expect(second.issue?.needsAction == true)
        }

        /// A recovery without an auth file and without an account email names no owner, so
        /// nothing ownerless is ever shown or kept.
        @Test func aFileLessRecoveryWithoutAnAccountShowsNothing() async throws {
            let bed = try CodexTestBed(
                recovery: FakeRecovery(account: nil, rateLimits: CodexFixtures.rateLimits))
            defer { bed.remove() }
            let account = try #require(try await bed.provider.fetch(previous: nil).accounts.first)
            #expect(!account.hasObservation)
            #expect(account.issue?.message == CodexError.signInChanged.localizedDescription)
        }

        /// CDX-04: a half-written `auth.json` is unknown, not a new owner.
        @Test func aHalfWrittenAuthFileKeepsTheReading() async throws {
            let half = Locked(false)
            let holder = Locked<TemporaryDirectory?>(nil)
            let http = FakeHTTPClient { _ in
                if half.value { try holder.value?.write(#"{"tokens":{"acc"#, to: "home/auth.json") }
                return .json(200, CodexFixtures.usage)
            }
            let bed = try CodexTestBed(http: http)
            defer { bed.remove() }
            holder.withLock { $0 = bed.root }
            try bed.writeAuth()
            let first = try await bed.provider.fetch(previous: nil)

            try bed.writeAuth("")
            #expect(await bed.provider.reconcile(first) == first)

            // Codex rewrites the file while the request runs.
            try bed.writeAuth()
            half.withLock { $0 = true }
            let second = try #require(try await bed.provider.fetch(previous: first).accounts.first)
            #expect(second.isStale)
            #expect(second.observedAt == first.accounts.first?.observedAt)
            #expect(second.issue?.message == CodexError.signInChanged.localizedDescription)
        }

        /// CDX-05: an unreadable file never yields an ownerless reading. An older owned reading
        /// stays stale, because unreadable is unknown. R3-P-02: nothing is sent or started.
        @Test func anUnreadableFileNeverYieldsAnOwnerlessReading() async throws {
            let bed = try CodexTestBed(
                recovery: FakeRecovery(rateLimits: CodexFixtures.rateLimits))
            defer { bed.remove() }
            try bed.writeAuth()
            let first = try await bed.provider.fetch(previous: nil)
            try FileManager.default.removeItem(at: bed.root.path("home/auth.json"))
            _ = try bed.root.makeDirectory("home/auth.json")

            let second = try #require(try await bed.provider.fetch(previous: first).accounts.first)

            #expect(bed.recovery.calls == 0)
            #expect(bed.http.requests.count == 1)
            #expect(second.isStale)
            #expect(second.owner == first.accounts.first?.owner)
            #expect(second.observedAt == first.accounts.first?.observedAt)
            #expect(second.issue?.message == CodexError.authFileUnreadable.localizedDescription)
        }

        /// CDX-06: an API-key result from recovery never keeps an old subscription reading,
        /// even while the file still names the same ChatGPT identity.
        @Test(arguments: [#"{"account":{"type":"apiKey"}}"#, #"{"account":null}"#])
        func codexSayingNoSubscriptionDropsTheReading(account: String) async throws {
            let failing = Locked(false)
            let http = FakeHTTPClient { _ in
                failing.value ? .json(401, "{}") : .json(200, CodexFixtures.usage)
            }
            let bed = try CodexTestBed(
                http: http, recovery: FakeRecovery(account: account, rateLimits: nil))
            defer { bed.remove() }
            try bed.writeAuth()
            let first = try await bed.provider.fetch(previous: nil)
            failing.withLock { $0 = true }

            let second = try #require(try await bed.provider.fetch(previous: first).accounts.first)

            #expect(bed.recovery.calls == 1)
            #expect(!second.hasObservation)
            #expect(second.windows.isEmpty)
            #expect(second.issue?.needsAction == true)
        }

        /// CDX-14: a home folder that does not exist has no login, starts no child process,
        /// and drops its reading.
        @Test func aMissingHomeFolderIsSignedOutWithoutRecovery() async throws {
            let bed = try CodexTestBed(extraHomes: ["work"])
            defer { bed.remove() }
            try bed.writeAuth()
            try bed.writeAuth(home: "work")
            let first = try await bed.provider.fetch(previous: nil)
            #expect(first.accounts.allSatisfy { $0.hasObservation })
            try FileManager.default.removeItem(at: bed.root.path("work"))

            #expect(await bed.provider.reconcile(first)?.accounts.map(\.name) == ["Codex"])
            let second = try await bed.provider.fetch(previous: first)
            let work = try #require(second.accounts.last)
            #expect(!work.hasObservation)
            #expect(work.issue?.message == CodexError.homeMissing.localizedDescription)
            #expect(bed.recovery.calls == 0)
        }

        // MARK: - Tables

        private static let identity = CodexLogin.chatGPT(
            CodexCredentials(accessToken: CodexFixtures.accessToken(), idToken: nil, accountID: nil)
        )
        private static let renewed = CodexLogin.chatGPT(
            CodexCredentials(
                accessToken: CodexFixtures.accessToken(tag: "renewed"), idToken: nil,
                accountID: nil))
        private static let otherIdentity = CodexLogin.chatGPT(
            CodexCredentials(
                accessToken: CodexFixtures.accessToken(user: "user-2"), idToken: nil,
                accountID: nil))
        private static let opaque1 = CodexLogin.chatGPT(
            CodexCredentials(accessToken: "opaque-1", idToken: nil, accountID: nil))
        private static let opaque2 = CodexLogin.chatGPT(
            CodexCredentials(accessToken: "opaque-2", idToken: nil, accountID: nil))
        private static let noTokens = CodexLogin.noTokens(fileDigest: "digest")
        private static let keyring = CodexAccountRefresh.CodexReport.signedIn(
            CodexFixtures.keyringOwner)

        /// CDX-19: every pair of file states before and after a request.
        @Test func verifiedOwnerTable() {
            typealias Report = CodexAccountRefresh.CodexReport
            let cases:
                [(CodexLogin, CodexLogin, CodexAccountRefresh.Source, Report?, AccountOwner?)] = [
                    (Self.identity, Self.renewed, .direct, nil, Self.identity.owner),
                    (Self.identity, Self.otherIdentity, .recovery, nil, nil),
                    (Self.identity, .missing, .recovery, Self.keyring, nil),
                    (Self.identity, .invalid, .direct, nil, nil),
                    (Self.opaque1, Self.opaque2, .direct, nil, nil),
                    (Self.opaque1, Self.opaque1, .direct, nil, Self.opaque1.owner),
                    (Self.opaque1, Self.opaque2, .recovery, nil, Self.opaque2.owner),
                    (Self.opaque1, .missing, .recovery, Self.keyring, nil),
                    (Self.noTokens, Self.identity, .recovery, nil, Self.identity.owner),
                    (Self.noTokens, Self.noTokens, .recovery, nil, Self.noTokens.owner),
                    (.missing, .missing, .recovery, Self.keyring, CodexFixtures.keyringOwner),
                    (.missing, .missing, .recovery, nil, nil),
                    (.missing, .missing, .recovery, .noCLI, nil),
                    (.missing, Self.identity, .recovery, nil, Self.identity.owner),
                    (.missing, .apiKey, .recovery, Self.keyring, nil),
                    (.unreadable, .unreadable, .recovery, nil, nil),
                    (.unreadable, .missing, .recovery, Self.keyring, nil),
                    (.invalid, .invalid, .recovery, nil, nil),
                    (.invalid, Self.opaque2, .recovery, nil, Self.opaque2.owner),
                ]
            for (index, (before, after, source, report, expected)) in cases.enumerated() {
                #expect(
                    CodexAccountRefresh.verifiedOwner(
                        before: before, after: after, source: source, report: report)
                        == expected, "case \(index)")
            }
        }

        /// R3-P-01: a failure belongs to the login that sent the request.
        @Test func failureAfterTheRequestTable() {
            let limited = CodexError.rateLimited(retryAt: .reference(120))
            let http = CodexError.httpStatus(500)
            let signedIn = OwnerStatus.signedIn
            let cases: [(CodexLogin, CodexLogin, CodexError, CodexError, OwnerStatus)] = [
                // Another login after the request: a sign-in change, owned by the new login.
                (
                    Self.identity, Self.otherIdentity, limited, .signInChanged,
                    signedIn(Self.otherIdentity.owner!)
                ),
                (Self.opaque1, Self.opaque2, http, .signInChanged, signedIn(Self.opaque2.owner!)),
                // The same login, renewed: the failure stays.
                (Self.identity, Self.renewed, limited, limited, signedIn(Self.identity.owner!)),
                // A file that cannot be read after it proves nothing: the failure stays.
                (Self.identity, .notReadInTime, limited, limited, .unknown),
                (Self.identity, .invalid, limited, limited, .unknown),
                // A sign-out after it: the failure stays, and the reading goes.
                (Self.identity, .apiKey, http, http, .signedOut),
            ]
            for (index, (before, after, error, expected, status)) in cases.enumerated() {
                let request = CodexAccountRefresh.RequestResult(
                    quota: .failure(error), source: .direct)
                guard
                    case .failed(let shown, let shownStatus) = CodexAccountRefresh.kind(
                        of: request, before: before, after: after)
                else {
                    Issue.record("case \(index) must fail")
                    continue
                }
                #expect(shown == expected, "case \(index)")
                #expect(shownStatus == status, "case \(index)")
            }
        }

        @Test func statusAfterAFailureTable() {
            typealias Report = CodexAccountRefresh.CodexReport
            let http = CodexError.httpStatus(500)
            let signedIn = OwnerStatus.signedIn
            let cases: [(CodexLogin, CodexError, Report?, OwnerStatus)] = [
                (Self.identity, http, nil, signedIn(Self.identity.owner!)),
                (Self.identity, .apiKeyOnly, nil, .signedOut),
                (Self.identity, .notSignedIn, .signedOut, .signedOut),
                (Self.identity, http, .noCLI, signedIn(Self.identity.owner!)),
                (Self.identity, http, Self.keyring, signedIn(Self.identity.owner!)),
                (.missing, http, Self.keyring, signedIn(CodexFixtures.keyringOwner)),
                (.missing, http, .noCLI, .signedOut),
                (.missing, http, nil, .unknown),
                (.invalid, http, nil, .unknown),
                (.unreadable, http, Self.keyring, .unknown),
                (.noHome, http, nil, .signedOut),
                (.apiKey, http, nil, .signedOut),
            ]
            for (index, (after, error, report, expected)) in cases.enumerated() {
                #expect(
                    CodexAccountRefresh.status(after: after, error: error, report) == expected,
                    "case \(index)")
            }
        }
    }
}
