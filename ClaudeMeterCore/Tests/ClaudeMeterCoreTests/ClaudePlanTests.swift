import Foundation
import Testing

@testable import ClaudeMeterCore

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

    @Test func planTierNames() {
        #expect(
            ClaudePlan.displayName(subscriptionType: nil, rateLimitTier: "default_claude_max_5x")
                == "Max 5x")
        #expect(
            ClaudePlan.displayName(subscriptionType: nil, rateLimitTier: "default_claude_max_20x")
                == "Max 20x")
        // A tier with 5x/20x detail refines a bare "max" subscriptionType.
        #expect(
            ClaudePlan.displayName(subscriptionType: "max", rateLimitTier: "default_claude_max_5x")
                == "Max 5x")
        #expect(ClaudePlan.displayName(subscriptionType: "max", rateLimitTier: nil) == "Max")
        #expect(ClaudePlan.displayName(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
    }
}
