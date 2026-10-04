import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct OwnershipTests {
    private let alice = AccountOwner.identity("alice")
    private let bob = AccountOwner.identity("bob")

    private func usage(owner: AccountOwner?, observed: Bool = true) -> AccountUsage {
        AccountUsage(id: "a", name: "A", observedAt: observed ? .reference() : nil, owner: owner)
    }

    @Test func sameOwnerKeepsTheObservation() {
        #expect(usage(owner: alice).belongs(to: .signedIn(alice)))
    }

    @Test func changedOwnerDropsTheObservation() {
        #expect(!usage(owner: alice).belongs(to: .signedIn(bob)))
        #expect(!usage(owner: nil).belongs(to: .signedIn(bob)))
    }

    @Test func signingOutDropsTheObservation() {
        #expect(!usage(owner: alice).belongs(to: .signedOut))
    }

    @Test func temporaryReadFailureKeepsTheObservation() {
        #expect(usage(owner: alice).belongs(to: .unknown))
    }

    @Test func unavailableAccountsAlwaysBelong() {
        #expect(usage(owner: nil, observed: false).belongs(to: .signedOut))
    }

    @Test func onlyIdentityOwnersPersist() {
        #expect(AccountOwner.identity("x").isPersistable)
        #expect(!AccountOwner.credential("x").isPersistable)
    }

    @Test func diagnosticFactsAreRedacted() {
        #expect(DiagnosticFact("Email", "me@example.com").value == "[redacted]")
    }
}
