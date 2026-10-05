import Foundation
import MeterDomain
import MeterPlatform
import Testing

@testable import ProviderGrok

@Suite struct GrokFailureTests {
    /// The sentence that tells the user what to do. The switch has no `default`, so a new case
    /// does not compile until it states its instruction.
    private func instruction(for failure: GrokFailure) -> String {
        switch failure {
        case .signedOut: "Install grok and run `grok login`."
        case .sessionExpired: "Open Grok Build to renew it."
        case .sessionRejected: "Open Grok Build and run `grok login`."
        case .accessDenied: "Check your Grok plan."
        case .rateLimited: "Claude Meter will try again later."
        case .offline: "Check your internet connection."
        case .credentialsUnreadable: "If this continues, run `grok login`."
        case .signInChanged: "Refresh again to show the new account."
        case .httpStatus, .unexpectedResponse, .timedOut, .network, .credentialsBusy:
            "Claude Meter will try again soon."
        }
    }

    @Test(arguments: GrokFailure.allCases)
    func everyMessageEndsWithWhatToDo(failure: GrokFailure) {
        let message = failure.issue.message
        #expect(message.hasSuffix(" " + instruction(for: failure)), "\(message)")
    }

    /// Only a network that is down asks the user to check the connection. A connection that
    /// dropped had reached Grok, so the next refresh tries again.
    @Test func transportErrorsMapToTheirFailure() {
        let cases: [(HTTPError, GrokFailure)] = [
            (.offline, .offline), (.connectionLost, .network), (.timedOut, .timedOut),
            (.transport(code: -1), .network), (.redirectRejected, .unexpectedResponse),
            (.responseTooLarge(limit: 1), .unexpectedResponse),
        ]
        for (error, failure) in cases {
            #expect(GrokFailure(transport: error) == failure, "\(error)")
        }
        #expect(
            GrokFailure(transport: HTTPError.connectionLost).issue.message
                == "The Grok usage request failed. Claude Meter will try again soon.")
    }
}
