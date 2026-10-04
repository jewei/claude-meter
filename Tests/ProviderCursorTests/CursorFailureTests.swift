import Foundation
import MeterDomain
import Testing

@testable import ProviderCursor

@Suite struct CursorFailureTests {
    @Test func everyMessageTellsTheUserWhatToDo() {
        let failures: [CursorFailure] = [
            .signedOut, .sessionExpired, .sessionRejected, .accessDenied, .usageDisabled,
            .rateLimited(retryAt: nil), .httpStatus(500), .unexpectedResponse, .responseTooLarge,
            .unexpectedToken,
            .offline, .timedOut, .network, .credentialsBusy, .credentialsTimedOut,
            .credentialsUnreadable, .keychainUnavailable, .keychainDenied, .keychainFailed,
            .signInChanged, .invalidDate,
        ]
        let instructions = [
            "Open Cursor", "Check", "Claude Meter will", "Update", "Unlock", "Refresh", "Set",
            "Allow access",
        ]
        for failure in failures {
            let message = failure.issue.message
            #expect(instructions.contains { message.contains($0) }, "\(message)")
        }
    }
}
