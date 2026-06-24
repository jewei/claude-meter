import Foundation
import Testing
@testable import ClaudeMeterCore

@Suite("AnthropicStatusClient")
struct AnthropicStatusClientTests {
    @Test func parsesOperationalStatus() throws {
        let json = """
        {"page":{"id":"x"},"status":{"indicator":"none","description":"All Systems Operational"}}
        """
        let status = try #require(AnthropicStatusClient.parse(json.data(using: .utf8)!))
        #expect(status.level == .operational)
        #expect(!status.level.isIncident)
    }

    @Test func parsesIncidentStatus() throws {
        let json = """
        {"status":{"indicator":"major","description":"Elevated errors on the API"}}
        """
        let status = try #require(AnthropicStatusClient.parse(json.data(using: .utf8)!))
        #expect(status.level == .major)
        #expect(status.level.isIncident)
        #expect(status.description == "Elevated errors on the API")
    }

    @Test func unknownIndicatorTreatedAsMinor() {
        #expect(ServiceStatusLevel.from(indicator: "weird") == .minor)
    }

    @Test func returnsNilForGarbage() {
        #expect(AnthropicStatusClient.parse(Data("not json".utf8)) == nil)
    }
}

@Suite("ClaudePlan")
struct ClaudePlanTests {
    @Test func prefersSubscriptionTypeOverTier() {
        #expect(ClaudePlan.displayName(subscriptionType: "max", rateLimitTier: "pro") == "Max")
    }

    @Test func fallsBackToRateLimitTier() {
        #expect(ClaudePlan.displayName(subscriptionType: nil, rateLimitTier: "claude_pro") == "Pro")
    }

    @Test func returnsNilWhenUnknown() {
        #expect(ClaudePlan.displayName(subscriptionType: "", rateLimitTier: nil) == nil)
        #expect(ClaudePlan.displayName(subscriptionType: "mystery", rateLimitTier: nil) == nil)
    }
}
