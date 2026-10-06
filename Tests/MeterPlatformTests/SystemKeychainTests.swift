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

    @Test func theSecurityToolReadFailsClosedInTests() {
        #expect(throws: KeychainError.unavailable) {
            try SystemKeychain().passwordThroughSecurityTool(
                service: "Claude Code-credentials", account: "user")
        }
    }

    @Test func securityToolOutputIsTheSecret() {
        let json = #"{"claudeAiOauth":{}}"#
        #expect(SecurityTool.secret(fromOutput: Data((json + "\n").utf8)) == Data(json.utf8))
        // A secret that is not printable text comes out as hex digits.
        #expect(SecurityTool.secret(fromOutput: Data("00ff7a\n".utf8)) == Data([0, 255, 122]))
        #expect(SecurityTool.secret(fromOutput: Data("plain\n".utf8)) == Data("plain".utf8))
        #expect(SecurityTool.secret(fromOutput: Data()) == Data())
    }

    @Test func securityToolExitStatusesMapToKeychainErrors() {
        #expect(SecurityTool.error(exitStatus: 0) == nil)
        #expect(SecurityTool.error(exitStatus: 44) == .notFound)
        #expect(SecurityTool.error(exitStatus: 36) == .failure(.unavailable))
        #expect(SecurityTool.error(exitStatus: 128) == .failure(.unavailable))
        #expect(SecurityTool.error(exitStatus: 51) == .failure(.denied))
        #expect(SecurityTool.error(exitStatus: 1) == .failure(.failure(status: 1)))
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
