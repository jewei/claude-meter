import Foundation
import MeterDomain
import MeterPlatform
import MeterTestSupport
import Testing

@testable import ProviderClaude

extension ClaudeTests {
    /// Connects of the same pasted tokens that overlap. The server spends a refresh token when
    /// it rotates it, so a Connect must use the rotation that another Connect got, also when
    /// that Connect looked for one before the rotation arrived, and a rejection forgets only
    /// the rotation that the server rejected.
    @Suite struct OverlappingConnectTests {
        /// The pasted tokens. The server answers their access token with HTTP 401.
        private func connect(_ provider: ClaudeProvider) async throws {
            try await provider.connectManually(
                accessToken: "stale", refreshToken: "pasted", expiresAt: nil)
        }

        /// Rotates each refresh token once (``ClaudeFixtures/rotation(of:spent:)``), after
        /// `beforeRefresh` with the number of the token request, from 1. Answers each usage
        /// check with `check`, by access token and by the number of checks of that token, from
        /// 1.
        private func server(
            spent: Locked<[String]>,
            beforeRefresh: @escaping @Sendable (Int) async -> Void = { _ in },
            check: @escaping @Sendable (_ token: String, _ number: Int) async -> HTTPResponse
        ) -> FakeHTTPClient {
            let refreshes = Locked(0)
            let checks = Locked<[String: Int]>([:])
            return FakeHTTPClient { request in
                if request.url == TokenRefresher.url {
                    let number = refreshes.withLock { count in
                        count += 1
                        return count
                    }
                    await beforeRefresh(number)
                    return ClaudeFixtures.rotation(of: request, spent: spent)
                }
                let token = bearer(request) ?? ""
                let number = checks.withLock { counts in
                    counts[token, default: 0] += 1
                    return counts[token, default: 0]
                }
                return await check(token, number)
            }
        }

        /// Two Connects of the pasted tokens get HTTP 401. The first spends the pasted refresh
        /// token, slowly, and stores nothing, because the second started after it. The second
        /// looked for a rotation before the refresh ended, and gets its HTTP 401 after the
        /// refresh ended and the clock moved `elapsed` seconds. Returns the refresh tokens
        /// that the server got, in order.
        private func overlappingConnects(_ harness: ClaudeHarness, elapsed: TimeInterval)
            async throws -> [String]
        {
            let spent = Locked<[String]>([])
            let (refreshing, secondCheck) = (Gate(), Gate())
            let http = server(spent: spent) { number in
                if number == 1 { await refreshing.wait() }
            } check: { token, number in
                guard token == "stale" else { return .json(200, "{}") }
                if number == 2 { await secondCheck.wait() }
                return .json(401, "{}")
            }
            let provider = harness.provider(http)

            let first = Task { try await connect(provider) }
            #expect(await refreshing.waitForArrivals())
            let second = Task { try await connect(provider) }
            #expect(await secondCheck.waitForArrivals())
            refreshing.open()
            let error = await #expect(throws: ProviderError.self) { try await first.value }
            #expect(
                error?.issue.message
                    == "The Claude connection changed while the tokens were checked. Try again.")
            harness.advance(elapsed)
            secondCheck.open()
            try await second.value
            return spent.value
        }

        @Test func aConnectThatOverlapsARefreshUsesItsRotation() async throws {
            let harness = try ClaudeHarness(.off)

            let spent = try await overlappingConnects(harness, elapsed: 0)

            // The spent refresh token went out once, and the rotation that it got is stored.
            #expect(spent == ["pasted"])
            let item = try #require(harness.manualItem())
            #expect(item.accessToken == "access-pasted")
            #expect(item.refreshToken == "next-pasted")
        }

        @Test func aConnectThatOverlapsARefreshRenewsItsExpiredRotation() async throws {
            let harness = try ClaudeHarness(.off)

            let spent = try await overlappingConnects(harness, elapsed: 3_600)

            // The rotation expired, so it was refreshed with its own refresh token.
            #expect(spent == ["pasted", "next-pasted"])
            let item = try #require(harness.manualItem())
            #expect(item.accessToken == "access-next-pasted")
            #expect(item.refreshToken == "next-next-pasted")
        }

        @Test func aRejectedRefreshTokenKeepsANewerRotation() async throws {
            let harness = try ClaudeHarness(.off)
            let spent = Locked<[String]>([])
            let (refreshing, failing) = (Gate(), Locked(true))
            let http = server(spent: spent) { number in
                if number == 1 { await refreshing.wait() }
            } check: { token, _ in
                guard token != "stale" else { return .json(401, "{}") }
                return failing.value ? .json(503, "{}") : .json(200, "{}")
            }
            let provider = harness.provider(http)

            // A Connect sends the pasted refresh token, slowly, and a Disconnect starts.
            let slow = Task { try await connect(provider) }
            #expect(await refreshing.waitForArrivals())
            try await provider.disconnectManual()
            // A new Connect spends the pasted refresh token first. Its check fails, so it keeps
            // the rotation in memory.
            await #expect(throws: ProviderError.self) { try await connect(provider) }
            // Then the server rejects the slow refresh, whose token is spent now.
            refreshing.open()
            let error = await #expect(throws: ProviderError.self) { try await slow.value }
            #expect(
                error?.issue.message == "Anthropic rejected the refresh token. Enter new tokens.")

            // The rotation does not hold the rejected token, so a retry uses it.
            failing.withLock { $0 = false }
            try await connect(provider)
            #expect(spent.value == ["pasted", "pasted"])
            #expect(harness.manualItem()?.accessToken == "access-pasted")
        }

        @Test func aRejectedCheckKeepsANewerRotation() async throws {
            let harness = try ClaudeHarness(.off)
            let spent = Locked<[String]>([])
            let (checking, failing) = (Gate(), Locked(true))
            let http = server(spent: spent) { token, number in
                switch token {
                case "stale":
                    return .json(401, "{}")
                case "access-pasted" where number == 2:
                    await checking.wait()
                    return .json(401, "{}")
                default:
                    return failing.value ? .json(503, "{}") : .json(200, "{}")
                }
            }
            let provider = harness.provider(http)

            // A Connect gets a rotation, and its check fails, so it keeps the rotation.
            await #expect(throws: ProviderError.self) { try await connect(provider) }
            // A retry checks the rotation, slowly.
            let slow = Task { try await connect(provider) }
            #expect(await checking.waitForArrivals())
            // The rotation expires. Another retry refreshes it, and keeps the newer rotation.
            harness.advance(3_600)
            await #expect(throws: ProviderError.self) { try await connect(provider) }
            // Then the server rejects the first rotation for the slow retry.
            checking.open()
            let error = await #expect(throws: ProviderError.self) { try await slow.value }
            #expect(
                error?.issue.message
                    == "Anthropic rejected these tokens. Check them and try again.")

            // The newer rotation is not the one that the server rejected, so a retry uses it.
            failing.withLock { $0 = false }
            try await connect(provider)
            #expect(spent.value == ["pasted", "next-pasted"])
            #expect(harness.manualItem()?.accessToken == "access-next-pasted")
        }
    }
}
