import Foundation
import MeterPlatform
import MeterTestSupport
import Testing

@Suite struct RetryAfterTests {
    @Test func acceptsDeltaSeconds() {
        #expect(RetryAfter.delay("120", now: .reference()) == 120)
        #expect(RetryAfter.delay(" 5 ", now: .reference()) == 5)
    }

    @Test func rejectsInvalidValues() {
        for value in ["0", "-5", "0x10", "1e3", "abc", "", nil] as [String?] {
            #expect(RetryAfter.delay(value, now: .reference()) == nil)
        }
    }

    @Test func acceptsFutureHTTPDates() {
        // 2026-10-04T12:00:00Z is the reference date.
        #expect(RetryAfter.delay("Sun, 04 Oct 2026 12:01:30 GMT", now: .reference()) == 90)
        #expect(RetryAfter.delay("Sun, 04 Oct 2026 11:59:00 GMT", now: .reference()) == nil)
    }

    @Test func clampsHugeValues() {
        for value in [
            "99999999999999999999999", String(repeating: "9", count: 400),
            "Fri, 31 Dec 9999 23:59:59 GMT",
        ] {
            #expect(RetryAfter.delay(value, now: .reference()) == RetryAfter.maximum)
        }
    }
}

@Suite struct JWTTests {
    @Test func readsExpiryAndNestedClaims() throws {
        let token = JWTFixture.token(
            expiresAt: .reference(60),
            extra: ["https://api.openai.com/auth": ["chatgpt_account_id": "acct"], "sub": "user"])
        let claims = try #require(JWTClaims(token: token))
        #expect(claims.expiresAt == .reference(60))
        #expect(claims.string("https://api.openai.com/auth", "chatgpt_account_id") == "acct")
        #expect(claims.string("sub") == "user")
        #expect(claims.string("missing") == nil)
    }

    @Test func ignoresNonNumericExpiry() throws {
        let claims = try #require(JWTClaims(token: JWTFixture.token(["exp": true])))
        #expect(claims.expiresAt == nil)
        let text = try #require(JWTClaims(token: JWTFixture.token(["exp": "1791115200"])))
        #expect(text.expiresAt == nil)
    }

    @Test func rejectsMalformedTokens() {
        #expect(JWTClaims(token: "not-a-token") == nil)
        #expect(JWTClaims(token: "a.b") == nil)
        #expect(JWTClaims(token: "a.%%%.c") == nil)
        #expect(JWTClaims(token: String(repeating: "a", count: 70_000)) == nil)
    }
}

@Suite struct DateParsingTests {
    @Test func parsesISO8601Variants() {
        let expected = Date(timeIntervalSince1970: 1_791_115_200)
        #expect(DateParsing.iso8601("2026-10-04T12:00:00Z") == expected)
        #expect(DateParsing.iso8601("2026-10-04T12:00:00.000Z") == expected)
        #expect(DateParsing.iso8601("2026-10-04T14:00:00+02:00") == expected)
        let micro = DateParsing.iso8601("2026-10-04T12:00:00.123456Z")
        #expect(micro.map { abs($0.timeIntervalSince(expected) - 0.123) < 0.001 } == true)
        #expect(DateParsing.iso8601("yesterday") == nil)
    }

    @Test func parsesEpochSecondsAndMilliseconds() {
        #expect(DateParsing.epoch(1_791_115_200) == .reference())
        #expect(DateParsing.epoch(1_791_115_200_000) == .reference())
        #expect(DateParsing.epoch(0) == nil)
        #expect(DateParsing.epoch(.infinity) == nil)
        #expect(DateParsing.date(.string("1791115200")) == .reference())
        #expect(DateParsing.date(.number(1_791_115_200)) == .reference())
        #expect(DateParsing.date(.bool(true)) == nil)
    }

    @Test func rejectsDatesOutsideTheBounds() {
        #expect(DateParsing.iso8601("3001-01-01T00:00:00Z") == nil)
    }

    @Test func rejectsTimesWithoutAZone() {
        #expect(DateParsing.iso8601("2026-10-04T12:00:00") == nil)
        #expect(DateParsing.iso8601("2026-10-04T12:00:00.5") == nil)
        #expect(DateParsing.iso8601("2026-10-04T12:00:00.123456") == nil)
        #expect(DateParsing.iso8601("2026-10-04T14:00:00.5+02:00") == .reference(0.5))
    }
}

@Suite struct NumericTextTests {
    @Test func acceptsDecimalText() {
        #expect(NumericText.double("12") == 12)
        #expect(NumericText.double("-1.5") == -1.5)
        #expect(NumericText.double("1e3") == 1000)
    }

    @Test func rejectsOtherForms() {
        for text in ["0x10", " 1", "1 ", "inf", "nan", "", "1."] {
            #expect(NumericText.double(text) == nil)
        }
    }
}

@Suite struct DigestTests {
    @Test func hashesText() {
        #expect(
            Digest.sha256("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func separatesParts() {
        #expect(Digest.sha256(parts: ["ab", "c"]) != Digest.sha256(parts: ["a", "bc"]))
    }
}

@Suite struct KeyValueStoreTests {
    @Test func roundTripsCodableValues() {
        let store = MemoryStore()
        store.setValue(["a": 1], forKey: "numbers")
        #expect(store.value([String: Int].self, forKey: "numbers") == ["a": 1])
        store.setValue(nil as [String: Int]?, forKey: "numbers")
        #expect(store.data(forKey: "numbers") == nil)
    }

    @Test func invalidDataReadsAsMissing() {
        let store = MemoryStore(["bad": Data("{".utf8)])
        #expect(store.value([String: Int].self, forKey: "bad") == nil)
    }
}
