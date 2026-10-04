import Foundation
import MeterDomain
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
}
