import Testing

@testable import ClaudeMeterCore

@Suite("UsageThresholds")
struct UsageThresholdsTests {

    @Test("Default thresholds match legacy 80/95 bands")
    func defaults() {
        let t = UsageThresholds.default
        #expect(t.severity(for: 79) == .normal)
        #expect(t.severity(for: 80) == .warning)
        #expect(t.severity(for: 94) == .warning)
        #expect(t.severity(for: 95) == .critical)
        #expect(t.severity(for: 101) == .overLimit)
    }

    @Test("Custom thresholds change severity bands")
    func custom() {
        let t = UsageThresholds(warning: 70, critical: 90)
        #expect(t.severity(for: 69) == .normal)
        #expect(t.severity(for: 75) == .warning)
        #expect(t.severity(for: 92) == .critical)
    }

    @Test("Non-finite values have unknown severity")
    func nonFinite() {
        let t = UsageThresholds.default
        #expect(t.severity(for: .nan) == .unknown)
        #expect(t.severity(for: .infinity) == .unknown)
        #expect(t.severity(for: -.infinity) == .unknown)
    }
}
