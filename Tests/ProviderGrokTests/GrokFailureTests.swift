import Foundation
import MeterDomain
import Testing

@testable import ProviderGrok

@Suite struct GrokFailureTests {
    @Test func everyMessageTellsTheUserWhatToDo() {
        let failures: [GrokFailure] = [
            .signedOut, .sessionExpired, .sessionRejected, .rateLimited(retryAt: nil),
            .httpStatus(500), .unexpectedResponse, .offline, .timedOut, .network,
            .credentialsUnreadable, .credentialsBusy, .signInChanged,
        ]
        let instructions = [
            "run `grok", "Open Grok Build", "Claude Meter will", "Check", "Refresh",
        ]
        for failure in failures {
            let message = failure.issue.message
            #expect(instructions.contains { message.contains($0) }, "\(message)")
        }
    }
}
