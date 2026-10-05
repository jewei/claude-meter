import Foundation
import MeterDomain
import Testing

@Suite struct ThresholdsTests {
    @Test(arguments: [
        (79.9, Severity.normal), (80, .warning), (94.9, .warning), (95, .critical),
        (99.9, .critical), (100, .exhausted), (0, .normal),
    ])
    func standardBands(used: Double, expected: Severity) {
        #expect(Thresholds.standard.severity(usedPercent: used) == expected)
    }

    @Test func unknownInputsAreUnknown() {
        #expect(Thresholds.standard.severity(usedPercent: nil) == .unknown)
        #expect(Thresholds.standard.severity(usedPercent: .nan) == .unknown)
        #expect(Thresholds.standard.severity(usedPercent: -1) == .unknown)
    }

    @Test func overLimitIsExhausted() {
        #expect(Thresholds.standard.severity(usedPercent: 50, isOverLimit: true) == .exhausted)
    }

    @Test func customBands() {
        let thresholds = Thresholds(warning: 70, critical: 90)
        #expect(thresholds.severity(usedPercent: 69) == .normal)
        #expect(thresholds.severity(usedPercent: 75) == .warning)
        #expect(thresholds.severity(usedPercent: 92) == .critical)
    }

    @Test func clampsToRanges() {
        let thresholds = Thresholds(warning: 10, critical: 200)
        #expect(thresholds.warning == 50)
        #expect(thresholds.critical == 100)
    }

    @Test func keepsCriticalAboveWarning() {
        let thresholds = Thresholds(warning: 85, critical: 70)
        #expect(thresholds.critical == 90)
        #expect(Thresholds(warning: 90, critical: 60).critical == 95)
    }

    @Test func replacesNonFiniteValuesWithDefaults() {
        let thresholds = Thresholds(warning: .nan, critical: .infinity)
        #expect(thresholds == .standard)
    }

    @Test func decodingValidates() throws {
        let data = Data(#"{"warning":5,"critical":5}"#.utf8)
        let decoded = try JSONDecoder().decode(Thresholds.self, from: data)
        #expect(decoded.warning == 50)
        #expect(decoded.critical == 60)
    }

    @Test func severityOrder() {
        #expect(Severity.allCases == Severity.allCases.sorted())
        #expect(Severity.unknown < .normal)
        #expect(Severity.critical < .exhausted)
    }
}
