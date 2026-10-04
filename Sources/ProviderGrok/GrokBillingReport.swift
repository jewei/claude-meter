import Foundation
import MeterDomain
import MeterPlatform

/// The `v1/billing?format=credits` response, mapped to the domain model.
///
/// The endpoint sends protobuf JSON: it omits zero values, and it can send 64-bit integers as
/// strings. A present `currentPeriod` without `creditUsagePercent` means 0% used, and a money
/// value without `val` means zero. Money is `{"val": <US cents>}`.
struct GrokBillingReport: Hashable, Sendable {
    let window: QuotaWindow
    let onDemand: Balance
    let prepaid: Balance

    init(body: Data) throws(GrokFailure) {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body),
            let config = json["config"], case .object = config,
            let period = config["currentPeriod"], case .object = period
        else { throw .unexpectedResponse }

        let percent = config["creditUsagePercent"]
        window = QuotaWindow(
            id: "credits", title: Self.title(periodType: period["type"]?.stringValue),
            kind: .billing,
            usedPercent: percent == nil || percent == .null ? 0 : percent?.doubleValue,
            resetsAt: DateParsing.date(period["end"]))

        // A cap of zero means that on-demand spend has no cap.
        let cap = Self.dollars(config["onDemandCap"]).flatMap { $0 > 0 ? $0 : nil }
        onDemand = Balance(
            kind: .onDemand, amount: Self.dollars(config["onDemandUsed"]), limit: cap,
            unit: .currency("USD"))
        prepaid = Balance(
            kind: .prepaid, amount: Self.dollars(config["prepaidBalance"]), unit: .currency("USD"))
    }

    func account(owner: AccountOwner, now: Date) -> AccountUsage {
        AccountUsage(
            id: .default, name: GrokProvider.accountName, windows: [window],
            balances: [onDemand, prepaid], observedAt: now, attemptedAt: now, owner: owner)
    }

    static func title(periodType: String?) -> String {
        switch periodType {
        case "USAGE_PERIOD_TYPE_WEEKLY": "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": "Monthly"
        default: "Credits"
        }
    }

    /// `{"val": <cents>}` in dollars. A missing value or `val` is zero; a value that is not a
    /// number is unknown.
    static func dollars(_ money: JSONValue?) -> Decimal? {
        guard let money, money != .null else { return 0 }
        guard case .object = money else { return nil }
        let text: String
        switch money["val"] {
        case nil, .null?:
            return 0
        case .number(let number)? where number.isFinite:
            text = String(number)
        case .string(let string)? where NumericText.double(string) != nil:
            text = string
        default:
            return nil
        }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")).map { $0 / 100 }
    }
}
