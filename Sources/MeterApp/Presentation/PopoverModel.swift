import Foundation
import MeterDomain

/// Everything the popover shows, built from one ``PresentationContext``.
public struct PopoverModel: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// A spinner with a message.
        case loading(String)
        /// A full-size message with one action: welcome, paused, nothing set up, or an error.
        case status(StatusScreen)
        case accounts(AccountsModel)
    }

    /// `2m ago` for the main meter's observation. Nil before onboarding.
    public let updatedText: String?
    public let showsUpdateNotice: Bool
    public let content: Content

    public init(_ context: PresentationContext) {
        let settings = context.settings
        let onboarded = settings.hasCompletedOnboarding
        let meter = MainMeter(context)
        updatedText =
            onboarded ? Formatting.age(since: meter.selected?.observedAt, now: context.now) : nil
        showsUpdateNotice = context.isUpdateAvailable
        content = Self.content(context, meter: meter)
    }

    private static func content(_ context: PresentationContext, meter: MainMeter) -> Content {
        let settings = context.settings
        guard settings.hasCompletedOnboarding else { return .status(.onboarding) }

        let automatic = CardBuilder(context: context, meter: meter).cards()
        let enabled = settings.enabledProviders
        // Sources whose switch is on, with Claude counted before it is connected.
        let switchedOn = settings.claude.needsConnection ? enabled.union([.claude]) : enabled
        if settings.isPaused, automatic.isEmpty { return .status(.paused) }
        guard !switchedOn.isEmpty else { return .status(.noSources) }
        if automatic.isEmpty {
            // Only a first reading loads; a retry after a failure keeps the error screen.
            if enabled.contains(where: context.isLoadingFirstReading) {
                return .loading(loadingMessage(enabled))
            }
            if let (provider, issue) = firstFailure(context, meter: meter) {
                return .status(.error(provider, message: issue.message))
            }
            return .status(.setup(switchedOn))
        }
        return .accounts(AccountsModel(context, meter: meter, automatic: automatic))
    }

    private static func loadingMessage(_ enabled: Set<ProviderID>) -> String {
        guard enabled.count == 1, let only = enabled.first else { return "Checking your tanks…" }
        return "Checking \(only.displayName)…"
    }

    /// The main provider's failure first, then the others in provider order.
    private static func firstFailure(
        _ context: PresentationContext, meter: MainMeter
    ) -> (ProviderID, UsageIssue)? {
        let order = [meter.provider] + ProviderID.allCases.filter { $0 != meter.provider }
        for provider in order where context.isEnabled(provider) {
            if let issue = context.readings[provider]?.issue { return (provider, issue) }
        }
        return nil
    }
}
