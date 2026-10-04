import Foundation
import MeterDomain
import MeterPlatform
import Testing

@testable import ProviderCursor

@Suite struct CursorFailureTests {
    /// The sentence that tells the user what to do. The switch has no `default`, so a new case
    /// does not compile until it states its instruction.
    private func instruction(for failure: CursorFailure) -> String {
        switch failure {
        case .signedOut: "Open Cursor and sign in."
        case .sessionExpired: "Open Cursor to renew it."
        case .sessionRejected: "Open Cursor and sign in again."
        case .accessDenied: "Check your Cursor account permissions."
        case .usageDisabled: "Check the account in the Cursor dashboard."
        case .rateLimited: "Claude Meter will try again later."
        case .responseTooLarge: "Check your usage in the Cursor dashboard."
        case .unexpectedToken: "Update Claude Meter if this continues."
        case .offline: "Check your internet connection."
        case .credentialsUnreadable: "Open Cursor and try again."
        case .keychainUnavailable: "Unlock your Mac and try again."
        case .keychainDenied: "Allow access in Keychain Access, or sign in to the Cursor app."
        case .signInChanged: "Refresh again to show the new account."
        case .invalidDate: "Set the correct date and time."
        case .httpStatus, .unexpectedResponse, .timedOut, .network, .credentialsBusy,
            .credentialsTimedOut, .keychainFailed:
            "Claude Meter will try again soon."
        }
    }

    @Test(arguments: CursorFailure.allCases)
    func everyMessageEndsWithWhatToDo(failure: CursorFailure) {
        let message = failure.issue.message
        #expect(message.hasSuffix(" " + instruction(for: failure)), "\(message)")
    }

    /// Only a network that is down asks the user to check the connection. A connection that
    /// dropped had reached Cursor, so the next refresh tries again.
    @Test func transportErrorsMapToTheirFailure() {
        let cases: [(HTTPError, CursorFailure)] = [
            (.offline, .offline), (.connectionLost, .network), (.timedOut, .timedOut),
            (.transport(code: -1), .network), (.redirectRejected, .unexpectedResponse),
            (.responseTooLarge(limit: 1), .responseTooLarge),
        ]
        for (error, failure) in cases {
            #expect(CursorFailure(transport: error) == failure, "\(error)")
        }
        #expect(
            CursorFailure(transport: HTTPError.connectionLost).issue.message
                == "The Cursor request failed. Claude Meter will try again soon.")
    }
}
