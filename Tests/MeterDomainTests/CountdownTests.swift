import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@Suite struct CountdownTests {
    /// Two parts are joined with a no-break space, so the countdown stays on one line.
    @Test(
        arguments: [
            (1.0, "1m"), (29, "1m"), (30, "1m"), (89, "1m"), (90, "2m"),
            (.minutes(59.5), "1h"), (.hours(1), "1h"),
            (.hours(2) + .minutes(14), "2h\u{00A0}14m"), (.hours(3), "3h"),
            (.hours(11) + .minutes(59), "11h\u{00A0}59m"),
            (.hours(12), "12h"), (.hours(12) + .minutes(30), "12h"),
            (.hours(36) + .minutes(20), "36h"), (.hours(47), "47h"),
            (.hours(47) + .minutes(59) + 29, "47h"),
            (.hours(47) + .minutes(59) + 30, "2d"), (.hours(48), "2d"),
            (.hours(48) + .minutes(59), "2d"),
            (.days(3) + .hours(8), "3d\u{00A0}8h"), (.days(4), "4d"),
            (.days(6) + .hours(7) + .minutes(45), "6d\u{00A0}7h"),
            (.days(6) + .hours(23) + .minutes(59), "6d\u{00A0}23h"),
            (.days(7) - 30, "7d"),
        ] as [(TimeInterval, String)])
    func formats(seconds: TimeInterval, expected: String) {
        #expect(Countdown.text(until: .reference(seconds), now: .reference()) == expected)
    }

    @Test func pastAndInvalidDatesHaveNoText() {
        #expect(Countdown.text(until: .reference(0), now: .reference()) == nil)
        #expect(Countdown.text(until: .reference(-60), now: .reference()) == nil)
        #expect(Countdown.text(until: Date(timeIntervalSince1970: .nan), now: .reference()) == nil)
    }

    @Test func phraseAddsPreposition() {
        #expect(Countdown.phrase(until: .reference(.hours(3)), now: .reference()) == "in 3h")
        #expect(Countdown.phrase(until: .reference(-1), now: .reference()) == nil)
    }
}
