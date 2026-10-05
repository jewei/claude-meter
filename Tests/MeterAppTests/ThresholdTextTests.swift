import Foundation
import Testing

@testable import MeterApp

@Suite struct ThresholdTextTests {
    @Test func thresholdTextIsAWholePercentInRange() {
        #expect(ThresholdText.percent(80, in: 50...90) == "80%")
        #expect(ThresholdText.percent(72.6, in: 50...90) == "73%")
        #expect(ThresholdText.percent(120, in: 50...90) == "90%")
        #expect(ThresholdText.percent(.nan, in: 50...90) == "50%")
        #expect(ThresholdText.spoken(95, in: 60...100) == "95 percent")
    }
}
