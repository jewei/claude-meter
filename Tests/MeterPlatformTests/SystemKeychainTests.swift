import Foundation
import LocalAuthentication
import MeterTestSupport
import Security
import Testing

@testable import MeterPlatform

@Suite struct FakeKeychainTests {
    @Test func aServiceWithTwoAccountsReadsTheSameItemEveryTime() throws {
        let keychain = FakeKeychain()
        for account in ["zed", "alpha", "mid"] {
            keychain.store("secret-\(account)", service: "service", account: account)
        }
        for _ in 0..<20 {
            let data = try keychain.password(service: "service", account: nil)
            #expect(data == Data("secret-alpha".utf8))
        }
    }
}

@Suite struct SystemKeychainTests {
    @Test func failsClosedInTests() {
        #expect(TestProcess.isRunning)
        #expect(throws: KeychainError.unavailable) {
            try SystemKeychain().password(service: "Claude Code-credentials", account: nil)
        }
    }

    @Test func everyQueryFailsInsteadOfPrompting() throws {
        let query = SystemKeychain().baseQuery(service: "service", account: nil)
        // The documented value of the deprecated kSecUseAuthenticationUIFail.
        #expect(SystemKeychain.authenticationUIFail == "u_AuthUIF")
        #expect(query[kSecUseAuthenticationUI] as? String == "u_AuthUIF")
        let context = try #require(query[kSecUseAuthenticationContext] as? LAContext)
        #expect(context.interactionNotAllowed)
        #expect(query[kSecAttrService] as? String == "service")
        #expect(query[kSecAttrAccount] == nil)
    }
}
