import Foundation
import Testing

@testable import ClaudeMeterCore
@testable import ClaudeMeterProviders

@Suite("OAuthRefreshCoordinator")
struct OAuthRefreshCoordinatorTests {

    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private func creds(_ token: String) -> OAuthCredentials {
        OAuthCredentials(
            accessToken: "access-\(token)",
            refreshToken: token,
            expiresAt: Date().addingTimeInterval(3600),
            subscriptionType: "max"
        )
    }

    @Test("Concurrent refreshes of the same token run perform exactly once")
    func coalescesSameToken() async throws {
        OAuthRefreshCoordinator.resetForTesting()
        let counter = Counter()
        let result = creds("rotated")

        // Several callers race for the same token while perform is in-flight (the
        // sleep keeps the window open). All but one must join.
        let outcomes = try await withThrowingTaskGroup(of: OAuthCredentials.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await OAuthRefreshCoordinator.refresh(token: "tok") {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(50))
                        return result
                    }
                }
            }
            var collected: [OAuthCredentials] = []
            for try await value in group { collected.append(value) }
            return collected
        }

        #expect(await counter.count == 1)
        #expect(outcomes.count == 8)
        #expect(outcomes.allSatisfy { $0.accessToken == result.accessToken })
    }

    @Test("Different tokens each run their own perform")
    func distinctTokensDoNotCoalesce() async throws {
        OAuthRefreshCoordinator.resetForTesting()
        let counter = Counter()

        _ = try await withThrowingTaskGroup(of: OAuthCredentials.self) { group in
            for i in 0..<4 {
                group.addTask { [self] in
                    try await OAuthRefreshCoordinator.refresh(token: "tok-\(i)") {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(20))
                        return self.creds("tok-\(i)")
                    }
                }
            }
            for try await _ in group {}
            return []
        }

        #expect(await counter.count == 4)
    }

    @Test("A failing refresh propagates to every joined caller")
    func failurePropagatesToJoiners() async {
        OAuthRefreshCoordinator.resetForTesting()
        struct Boom: Error {}

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        _ = try await OAuthRefreshCoordinator.refresh(token: "dead") {
                            try await Task.sleep(for: .milliseconds(30))
                            throw Boom()
                        }
                        return false
                    } catch is Boom {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var all: [Bool] = []
            for await threw in group { all.append(threw) }
            return all
        }

        #expect(results.count == 4)
        #expect(results.allSatisfy { $0 })
    }
}
