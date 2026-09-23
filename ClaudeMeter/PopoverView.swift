import AppKit
import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppSettings.cursorSourceEnabledKey) private var cursorSourceEnabled = false
    @AppStorage(AppSettings.codexSourceEnabledKey) private var codexSourceEnabled = false
    @AppStorage(AppSettings.grokSourceEnabledKey) private var grokSourceEnabled = false
    @AppStorage(MeterSettings.cardStyleKey) private var cardStyle = "rings"
    @AppStorage(MeterSettings.progressionModeKey) private var progressionMode = "left"
    @AppStorage(MeterSettings.mainMeterProviderKey) private var mainMeterProvider = "claude"
    @AppStorage(AppSettings.oauthModeKey) private var oauthMode = ""
    @State private var now = Date()
    // Tracks whether the popover window is on screen (the view is retained,
    // hidden, across dismissals). Gates the ticker and, via the environment,
    // every continuous TimelineView animation — otherwise they keep the
    // display link alive and re-layout the hidden hierarchy every frame.
    @State private var isVisible = false
    /// Expanded non-Claude provider cards, mirrored from `AppSettings` so toggling
    /// re-renders. Empty by default — see `AppSettings.expandedProviderCards`.
    @State private var expandedCards: Set<String> = AppSettings.expandedProviderCards

    private var usageThresholds: UsageThresholds {
        AppState.currentThresholds()
    }

    // MARK: - Collapsible provider cards

    static let cursorCardID = "cursor"
    static let grokCardID = "grok"
    static let claudeSecondaryCardID = "secondary:claude"
    static let codexSecondaryCardID = "secondary:codex"
    static func codexCardID(_ accountID: String) -> String { "codex:\(accountID)" }

    struct SecondaryProviderPresentation {
        let model: AccountCardModel?
        let displayedPercent: Double?
        let band: EnergyBand
    }

    private func isExpanded(_ id: String) -> Bool { expandedCards.contains(id) }

    private func toggleCard(_ id: String) {
        if expandedCards.remove(id) == nil { expandedCards.insert(id) }
        AppSettings.expandedProviderCards = expandedCards
    }

    /// Brand marks follow the ink colour into dark mode. Deliberately *not*
    /// severity-tinted: the percentage beside them already carries that, and a
    /// red-tinted glyph reads as an alert rather than a brand.
    private var claudeMark: some View {
        Image("ClaudeLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 15, height: 15)
            .foregroundStyle(Color.pfInk)
    }

    private var codexMark: some View {
        Image("CodexLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 15, height: 15)
            .foregroundStyle(Color.pfInk)
    }

    /// Disclosure chevron for a collapsible card header.
    private func disclosure(_ expanded: Bool) -> some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.pfInkMuted)
            .rotationEffect(.degrees(expanded ? 0 : -90))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: expanded)
    }

    /// `true` when the user chose to display usage instead of energy-left.
    private var cardStyleValue: MeterSettings.CardStyle {
        MeterSettings.CardStyle(rawValue: cardStyle) ?? .rings
    }

    nonisolated static func accountCardStyle(
        requested: MeterSettings.CardStyle,
        provider: MainMeterProvider
    ) -> MeterSettings.CardStyle {
        switch provider {
        case .claude, .codex: requested
        }
    }

    private var showsUsage: Bool {
        (MeterSettings.ProgressionMode(rawValue: progressionMode) ?? .left) == .used
    }

    private var selectedProvider: MainMeterProvider {
        MainMeterProvider(rawValue: mainMeterProvider) ?? .claude
    }

    private var needsOnboarding: Bool {
        !hasCompletedOnboarding
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            PopoverTransitionBody(desiredExpandedCards: expandedCards) {
                VStack(spacing: 0) {
                    if appState.updateAvailable {
                        updateAvailableNotice
                    }
                    mainContent
                }
            }
        }
        // AppKit briefly makes the host taller than SwiftUI's committed fitting
        // size while expanding. Fill that proposal and pin content to the top so
        // the pane does not center itself, drift down, then snap back.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.pfPopover)
        .environment(\.popoverIsVisible, isVisible)
        .task(id: isVisible) {
            guard isVisible else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, isVisible else { return }
                now = Date()
            }
        }
        .onAppear {
            isVisible = true
            now = Date()
        }
        .onDisappear { isVisible = false }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 9) {
            RaisedTile(fill: .pfEnergyFull, size: 30, radius: 9) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            // Never wrap: the title reads as the app's name, and "Claude / Meter"
            // over two lines pushed the whole header to double height.
            Text("Claude Meter")
                .font(PFont.display(18, .semibold))
                .foregroundStyle(Color.pfInk)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 6)
            if !needsOnboarding {
                // Not fixed-size: with three buttons the header can run out of
                // room at 360 points, and the timestamp is the element that may
                // shrink. Letting it truncate keeps the controls from clipping.
                Text(updatedText)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .help("Last updated")
            }
            squareButton("gearshape.fill", help: "Settings", size: 28) {
                openSettingsAndCompleteOnboarding()
            }
            if !needsOnboarding {
                squareButton("power", help: "Quit Claude Meter", size: 28) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Main content

    private var hasCursor: Bool {
        cursorSourceEnabled && appState.cursorSnapshot != nil
    }

    private var hasCodex: Bool {
        codexSourceEnabled && appState.codexAccounts.contains { $0.observedAt != nil }
    }

    private var hasGrok: Bool {
        grokSourceEnabled && appState.grokSnapshot != nil
    }

    private var hasAnyData: Bool {
        appState.claudeSnapshot != nil || hasCursor || hasCodex || hasGrok
    }

    private var hasProviderState: Bool {
        Self.shouldRenderProviderSections(
            hasAnyData: hasAnyData,
            hasCodexLifecycle: codexSourceEnabled && !appState.codexAccounts.isEmpty)
    }

    nonisolated static func shouldRenderProviderSections(
        hasAnyData: Bool,
        hasCodexLifecycle: Bool
    ) -> Bool {
        hasAnyData || hasCodexLifecycle
    }

    @ViewBuilder
    private var mainContent: some View {
        if needsOnboarding {
            onboardingContent
        } else if !appState.isActive {
            if hasAnyData { dataState } else { inactiveState }
        } else if !appState.hasEnabledDataSource {
            noSourcesState
        } else if !hasAnyData && appState.mainMeterIsLoading {
            loadingState
        } else if hasProviderState {
            dataState
        } else if appState.mainMeterReading == nil, appState.mainMeterError != nil {
            mainMeterErrorState
        } else if appState.lastError != nil {
            errorState
        } else if cursorSourceEnabled && appState.cursorError != nil {
            cursorErrorState
        } else if codexSourceEnabled && !appState.codexAccounts.isEmpty {
            codexErrorState
        } else if grokSourceEnabled && appState.grokError != nil {
            grokErrorState
        } else {
            setupState
        }
    }

    // MARK: - Data state

    @ViewBuilder
    private var dataState: some View {
        VStack(spacing: 12) {
            if selectedProvider == .claude {
                claudeProviderSection(isPrimary: true)
                codexProviderSection(isPrimary: false)
            } else {
                codexProviderSection(isPrimary: true)
                claudeProviderSection(isPrimary: false)
            }
            if hasCursor, let cursor = appState.cursorSnapshot?.accounts.first {
                cursorNotices()
                cursorCard(cursor)
            }
            if hasGrok, let grok = appState.grokSnapshot?.accounts.first {
                grokNotices()
                grokCard(grok)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func claudeProviderSection(isPrimary: Bool) -> some View {
        if appState.claudeSnapshot != nil, AppSettings.oauthSourceEnabled {
            let models = accountModels
            if isPrimary {
                claudeNotices()
                if appState.mainMeterReading == nil {
                    selectedMeterUnavailable(provider: .claude)
                } else {
                    HeroView(
                        summary: appState.mainMeterIsStale
                            ? HeroSummary.stale(
                                providerName: "Claude",
                                recovery: oauthMode.isEmpty
                                    ? "Connect Claude OAuth in Settings"
                                    : "Claude data is out of date"
                            )
                            : HeroSummary.make(
                                models: primaryOrdered(models),
                                thresholds: usageThresholds,
                                now: now))
                }
                accountsSection(primaryOrdered(models))

                if let selected = appState.claudeAccounts.first(where: {
                    $0.id == appState.mainMeterReading?.accountID
                }),
                    let extra = selected.balances.first(where: { $0.id == "extra-usage" }),
                    extra.value != nil || extra.limit != nil
                {
                    extraUsageCard(
                        extra,
                        percent: selected.windows.first { $0.id == "extra-usage" }?.usedPercent)
                }
            } else {
                claudeSecondaryCard(models)
            }
        } else if isPrimary {
            selectedMeterUnavailable(provider: .claude)
        }
    }

    @ViewBuilder
    private func codexProviderSection(isPrimary: Bool) -> some View {
        if codexSourceEnabled {
            if isPrimary {
                ForEach(orderedCodexReadings) { reading in
                    codexNotices(reading)
                }
                if appState.mainMeterReading == nil {
                    selectedMeterUnavailable(provider: .codex)
                } else {
                    HeroView(
                        summary: appState.mainMeterIsStale
                            ? HeroSummary.stale(
                                providerName: "Codex", recovery: "Codex data is out of date")
                            : HeroSummary.make(
                                models: codexAccountModels,
                                thresholds: usageThresholds,
                                now: now))
                }
                if !codexAccountModels.isEmpty {
                    let style = Self.accountCardStyle(
                        requested: cardStyleValue,
                        provider: .codex)
                    VStack(spacing: 10) {
                        accountSectionHeader("ACCOUNTS", style: style)
                        ForEach(orderedCodexReadings) { reading in
                            codexAccountCard(reading, style: style)
                        }
                    }
                }
            } else {
                sectionLabel("CODEX")
                secondaryProviderCard(
                    name: "Codex",
                    models: codexAccountModels,
                    hasError: orderedCodexReadings.contains(where: { $0.lastError != nil }),
                    isStale: orderedCodexReadings.contains(where: {
                        $0.observedAt != nil
                            && MeterSettings.isSnapshotStale(lastPollAt: $0.observedAt, now: now)
                    }),
                    cardID: Self.codexSecondaryCardID
                ) {
                    codexMark
                }
            }
        } else if isPrimary {
            selectedMeterUnavailable(provider: .codex)
        }
    }

    private func claudeSecondaryCard(_ models: [AccountCardModel]) -> some View {
        VStack(spacing: 10) {
            secondaryProviderCard(
                name: "Claude",
                models: models,
                hasError: appState.lastError != nil,
                isStale: appState.claudeIsStale,
                cardID: Self.claudeSecondaryCardID
            ) {
                claudeMark
            }

        }
    }

    private func secondaryProviderCard<Mark: View>(
        name: String,
        models: [AccountCardModel],
        hasError: Bool,
        isStale: Bool,
        cardID: String? = nil,
        @ViewBuilder mark: () -> Mark
    ) -> some View {
        let presentation = Self.secondaryProviderPresentation(
            from: models,
            showsUsage: showsUsage,
            thresholds: usageThresholds,
            asOf: now)
        let displayedPercent = presentation.displayedPercent
        let band = presentation.band
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        let detail = Self.secondaryProviderDetail(
            hasError: hasError,
            isStale: isStale,
            accountCount: models.count)
        let expanded = cardID.map(isExpanded) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            if let cardID {
                Button {
                    toggleCard(cardID)
                } label: {
                    secondaryProviderHeader(
                        name: name,
                        plan: presentation.model?.plan,
                        displayedPercent: displayedPercent,
                        band: band,
                        tint: tint,
                        expanded: expanded,
                        mark: mark)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide \(name) details" : "Show \(name) details")
            } else {
                secondaryProviderHeader(
                    name: name,
                    plan: presentation.model?.plan,
                    displayedPercent: displayedPercent,
                    band: band,
                    tint: tint,
                    expanded: nil,
                    mark: mark)
            }
            EnergyBar(
                fraction: (displayedPercent ?? 0) / 100,
                color: tint,
                height: 12)
            Text(detail)
                .font(PFont.body(11, .semibold))
                .foregroundStyle(Color.pfInkMuted)
            if let cardID, expanded {
                Group {
                    Divider().overlay(Color.pfCardBorder)
                    secondaryAccountDetails(models)
                }
                .popoverDisclosure(id: cardID)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func secondaryProviderHeader<Mark: View>(
        name: String,
        plan: String?,
        displayedPercent: Double?,
        band: EnergyBand,
        tint: Color,
        expanded: Bool?,
        @ViewBuilder mark: () -> Mark
    ) -> some View {
        HStack(spacing: 7) {
            mark()
            Text(name)
                .font(PFont.display(14, .semibold))
                .foregroundStyle(Color.pfInk)
            if let plan { PlanBadge(plan: plan) }
            if let expanded { disclosure(expanded) }
            Spacer(minLength: 4)
            Text(displayedPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(PFont.display(14, .bold))
                .foregroundStyle(band == .full ? Color.pfInk : tint)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    private func secondaryAccountDetails(_ models: [AccountCardModel]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(model.label)
                            .font(PFont.display(12, .semibold))
                            .foregroundStyle(Color.pfInk)
                            .lineLimit(1)
                        if let plan = model.plan { PlanBadge(plan: plan) }
                        if model.isDuplicateLogin { DuplicateLoginBadge() }
                        Spacer(minLength: 0)
                    }
                    if let subtitle = model.subtitle {
                        Text(subtitle)
                            .font(PFont.body(10, .semibold))
                            .foregroundStyle(Color.pfInkMuted)
                            .lineLimit(1)
                    }
                    secondaryLimitRow("5-hr", window: model.session)
                    secondaryLimitRow("week", window: model.week)
                    if let opus = model.opus {
                        secondaryLimitRow("opus", window: opus)
                    }
                    ForEach(model.scoped) { scoped in
                        secondaryLimitRow(scoped.displayName.lowercased(), window: scoped.window)
                    }
                    if let resets = model.rateLimitResets {
                        CodexUsageResetsView(resets: resets, now: now)
                    }

                }
            }
        }
    }

    private func secondaryLimitRow(_ label: String, window: LimitWindow) -> some View {
        let resolved = window.resolved(asOf: now)
        let band = resolved.energyBand(thresholds: usageThresholds, asOf: now)
        return HStack(spacing: 6) {
            EnergyDot(color: band.color)
            Text(label)
                .font(PFont.body(11, .bold))
                .foregroundStyle(Color.pfInk)
            Text(resolved.displayText(usage: showsUsage, asOf: now) ?? "—")
                .font(PFont.display(11, .heavy))
                .foregroundStyle(resolved.percentUsed == nil ? Color.pfInkMuted : band.color)
                .monospacedDigit()
            if let resetsAt = resolved.resetsAt,
                let phrase = ResetPhrase.spoken(until: resetsAt, asOf: now)
            {
                Text("· \(phrase)")
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }

    nonisolated static func secondaryProviderPlan(
        from models: [AccountCardModel],
        asOf now: Date
    ) -> String? {
        secondaryProviderBinding(from: models, asOf: now)?.model.plan
    }

    nonisolated static func secondaryProviderPresentation(
        from models: [AccountCardModel],
        showsUsage: Bool,
        thresholds: UsageThresholds,
        asOf now: Date
    ) -> SecondaryProviderPresentation {
        guard let binding = secondaryProviderBinding(from: models, asOf: now) else {
            return SecondaryProviderPresentation(
                model: nil,
                displayedPercent: nil,
                band: .unknown)
        }
        return SecondaryProviderPresentation(
            model: binding.model,
            displayedPercent: showsUsage ? 100 - binding.left : binding.left,
            band: binding.model.band(thresholds, now))
    }

    private nonisolated static func secondaryProviderBinding(
        from models: [AccountCardModel],
        asOf now: Date
    ) -> (model: AccountCardModel, left: Double)? {
        models.compactMap { model in
            model.bindingLeft(now).map { (model: model, left: $0) }
        }.min { $0.left < $1.left }
    }

    nonisolated static func secondaryProviderDetail(
        hasError: Bool,
        isStale: Bool,
        accountCount: Int
    ) -> String {
        if hasError {
            return accountCount == 0
                ? "Refresh failed · no usage data"
                : "Refresh failed · showing last known data"
        }
        if isStale { return "Data may be stale" }
        if accountCount == 0 { return "No usage data" }
        return accountCount == 1 ? "1 account" : "\(accountCount) accounts"
    }

    private func selectedMeterUnavailable(provider: MainMeterProvider) -> some View {
        HeroView(
            summary: HeroSummary.unavailable(
                providerName: provider.displayName,
                detail: appState.mainMeterError
                    ?? "Turn on \(provider.displayName) in Data settings"))
    }

    @ViewBuilder
    private func claudeNotices() -> some View {
        if appState.lastError != nil {
            noticeBanner(
                pollErrorText, systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        }
        // A dead Claude Code sign-in otherwise fails silently — every OAuth error
        // falls through to the next source, so the numbers just quietly stop
        // moving and the cause is visible only in Diagnostics.
        if let issue = appState.oauthCredentialIssue {
            noticeBanner(
                issue.displayText(retryAt: appState.oauthRetryAt, now: now),
                systemImage: issue.needsUserAction
                    ? "key.slash.fill" : "clock.arrow.circlepath",
                tint: issue.needsUserAction ? .pfEnergyLow : .pfInkMuted)
        }
        if appState.claudeIsStale {
            let message =
                oauthMode.isEmpty
                ? "Claude data is stale — connect OAuth in Settings"
                : "Claude data may be stale"
            noticeBanner(message, systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    @ViewBuilder
    private func cursorNotices() -> some View {
        if appState.cursorError != nil {
            noticeBanner(
                appState.cursorError ?? "Cursor refresh failed — showing last known data",
                systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if appState.cursorIsStale {
            noticeBanner(
                "Cursor data may be outdated", systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    // MARK: - Accounts

    private func accountsSection(
        _ models: [AccountCardModel],
        title: String = "ACCOUNTS",
        provider: MainMeterProvider = .claude
    ) -> some View {
        let style = Self.accountCardStyle(requested: cardStyleValue, provider: provider)
        return VStack(spacing: 10) {
            accountSectionHeader(title, style: style)
            ForEach(models) { model in
                if style == .bars {
                    AccountBarCard(
                        model: model, now: now, thresholds: usageThresholds, usage: showsUsage)
                } else {
                    AccountRingCard(
                        model: model, now: now, thresholds: usageThresholds, usage: showsUsage)
                }
            }
        }
    }

    private func accountSectionHeader(
        _ title: String,
        style: MeterSettings.CardStyle
    ) -> some View {
        HStack {
            Text(title)
                .font(PFont.body(11, .heavy))
                .tracking(0.9)
                .foregroundStyle(Color.pfSectionLabel)
            Spacer()
            if style == .rings { RingLegend() }
        }
        .padding(.horizontal, 2)
    }

    private func primaryOrdered(_ models: [AccountCardModel]) -> [AccountCardModel] {
        guard let selectedID = appState.mainMeterReading?.accountID,
            let index = models.firstIndex(where: { $0.id == selectedID }),
            index != models.startIndex
        else { return models }
        var ordered = models
        let selected = ordered.remove(at: index)
        ordered.insert(selected, at: 0)
        return ordered
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(PFont.body(11, .heavy))
                .tracking(0.9)
                .foregroundStyle(Color.pfSectionLabel)
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private var orderedCodexReadings: [ProviderAccountSnapshot] {
        let selectedID = selectedProvider == .codex ? appState.mainMeterReading?.accountID : nil
        return appState.codexAccounts.sorted { lhs, rhs in
            if lhs.id == selectedID { return true }
            if rhs.id == selectedID { return false }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                == .orderedAscending
        }
    }

    private var codexAccountModels: [AccountCardModel] {
        orderedCodexReadings.compactMap(Self.codexAccountModel)
    }

    static func codexAccountModel(_ reading: ProviderAccountSnapshot) -> AccountCardModel? {
        guard let normalized = MainMeterReading(account: reading, provider: .codex) else {
            return nil
        }
        var model = AccountCardModel(mainMeterReading: normalized)
        model.rateLimitResets = reading.balances.first { $0.id == "usage-resets" }
        return model
    }

    private var accountModels: [AccountCardModel] {
        appState.claudeAccounts.map { account in
            let windows = account.resolvedWindows(asOf: now)
            func limit(_ window: UsageWindow?) -> LimitWindow {
                LimitWindow(
                    percentUsed: window?.isOverLimit == true ? 101 : window?.usedPercent,
                    resetsAt: window?.resetAt)
            }
            return AccountCardModel(
                id: account.id, label: account.label, plan: account.plan,
                subtitle: account.subtitle, session: limit(windows.first { $0.kind == .session }),
                week: limit(windows.first { $0.kind == .weekly }),
                opus: windows.first { $0.id == "seven_day_opus" }.map { limit($0) },
                scoped: windows.filter { $0.kind == .scoped && $0.id != "seven_day_opus" }.map {
                    ScopedLimitWindow(id: $0.id, window: limit($0))
                },
                isDuplicateLogin: appState.claudeDiagnostics.duplicateAccountKeys.contains(
                    account.id),
                lastError: account.lastError)
        }
    }

    // MARK: - Extra usage (pay-as-you-go overage)

    private func extraUsageCard(_ extra: BalanceItem, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("💳").font(.system(size: 13))
                Text("Extra usage")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                if extra.displayText == "Paused" {
                    Text("paused")
                        .font(PFont.body(10, .bold))
                        .foregroundStyle(Color.pfInkMuted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.pfTrack))
                }
                Spacer()
                Text(extraUsageText(extra))
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(Color.pfInk)
                    .monospacedDigit()
            }
            if let pct = percent {
                EnergyBar(fraction: min(1, pct / 100), color: .pfEnergyFull, height: 12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func extraUsageText(_ extra: BalanceItem) -> String {
        let symbol = extra.unit == "USD" || extra.unit == nil ? "$" : "\(extra.unit!) "
        let used =
            extra.value.map {
                String(format: "%@%.2f", symbol, NSDecimalNumber(decimal: $0).doubleValue)
            } ?? "—"
        if let limit = extra.limit, limit > 0 {
            return used
                + String(format: " / %@%.2f", symbol, NSDecimalNumber(decimal: limit).doubleValue)
        }
        return used
    }

    // MARK: - Cursor card (spend-based, shared left/used progression)

    private func cursorCard(_ cursor: ProviderAccountSnapshot) -> some View {
        let window = cursor.windows.first { $0.kind == .billing }
        let displayPercent = window?.displayPercent(showUsage: showsUsage)
        let band = EnergyBand(severity: window?.severity(thresholds: usageThresholds) ?? .unknown)
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        let expanded = isExpanded(Self.cursorCardID)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleCard(Self.cursorCardID)
            } label: {
                HStack(spacing: 7) {
                    Image("CursorLogo")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.pfInk)
                        .frame(width: 15, height: 15)
                    Text("Cursor")
                        .font(PFont.display(14, .semibold))
                        .foregroundStyle(Color.pfInk)
                    if let planName = cursor.plan {
                        PlanBadge(plan: planName, verbatim: true)
                    }
                    disclosure(expanded)
                    Spacer(minLength: 4)
                    Text(displayPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(PFont.display(14, .bold))
                        .foregroundStyle(band == .full ? Color.pfInk : tint)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide Cursor details" : "Show Cursor details")
            // Percent, bar and reset timing all stay visible when collapsed —
            // that's what makes collapsing safe as the default.
            EnergyBar(fraction: (displayPercent ?? 0) / 100, color: tint, height: 12)
            if let subtitle = Self.cursorSubtitle(cursor, asOf: now) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            if expanded {
                Group {
                    let buckets = cursor.windows.filter {
                        $0.kind == .scoped && $0.usedPercent != nil
                    }
                    if !buckets.isEmpty {
                        Divider().overlay(Color.pfCardBorder)
                        VStack(spacing: 7) {
                            ForEach(buckets) { bucket in
                                if let percentUsed = bucket.usedPercent,
                                    let displayedPercent = bucket.displayPercent(
                                        showUsage: showsUsage)
                                {
                                    cursorUsageRow(
                                        bucket.title, percentUsed: percentUsed,
                                        displayedPercent: displayedPercent)
                                }
                            }
                        }
                    }
                }
                .popoverDisclosure(id: Self.cursorCardID)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func cursorUsageRow(
        _ label: String,
        percentUsed: Double,
        displayedPercent: Double
    ) -> some View {
        let band = EnergyBand(severity: usageThresholds.severity(for: percentUsed))
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        let modeLabel = showsUsage ? "usage" : "energy left"
        return VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                Spacer()
                Text("\(Int(displayedPercent.rounded()))%")
                    .font(PFont.body(11, .bold))
                    .foregroundStyle(Color.pfInk)
                    .monospacedDigit()
            }
            EnergyBar(fraction: displayedPercent / 100, color: tint, height: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(modeLabel)")
        .accessibilityValue("\(Int(displayedPercent.rounded())) percent")
    }

    static func cursorSubtitle(_ account: ProviderAccountSnapshot, asOf now: Date) -> String? {
        var parts: [String] = []
        // Cursor's reported percentage includes bonus credit. Do not show a spend/limit ratio.
        if let spend = account.balances.first?.value {
            parts.append("\(dollars(spend)) spent")
        }
        if let end = account.windows.first(where: { $0.kind == .billing })?.resetAt,
            let phrase = ResetPhrase.spoken(until: end, asOf: now)
        {
            parts.append("Resets \(phrase)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func dollars(_ value: Decimal) -> String {
        String(format: "$%.2f", NSDecimalNumber(decimal: value).doubleValue)
    }

    // MARK: - Codex card (usage-based, local to the popover)

    @ViewBuilder
    private func codexAccountCard(
        _ reading: ProviderAccountSnapshot,
        style: MeterSettings.CardStyle
    ) -> some View {
        if style == .rings, let model = Self.codexAccountModel(reading) {
            AccountRingCard(
                model: model,
                now: now,
                thresholds: usageThresholds,
                usage: showsUsage)
        } else if reading.observedAt != nil {
            codexCard(reading)
        }
    }

    @ViewBuilder
    private func codexNotices(_ reading: ProviderAccountSnapshot) -> some View {
        if let error = reading.lastError {
            noticeBanner(
                "\(reading.label): \(error)",
                systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if MeterSettings.isSnapshotStale(lastPollAt: reading.observedAt, now: now) {
            noticeBanner(
                "\(reading.label) data may be outdated",
                systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    private func codexCard(_ account: ProviderAccountSnapshot) -> some View {
        let primary = account.windows.first { $0.id == "primary" }
        let displayPercent = codexDisplayPercent(primary)
        let band = EnergyBand(severity: primary?.severity(thresholds: usageThresholds) ?? .unknown)
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        let cardID = Self.codexCardID(account.id)
        let expanded = isExpanded(cardID)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleCard(cardID)
            } label: {
                HStack(spacing: 7) {
                    codexMark
                    Text(account.label)
                        .font(PFont.display(14, .semibold))
                        .foregroundStyle(Color.pfInk)
                        .lineLimit(1)
                    // The plan the provider actually reports, beside the name the
                    // user gave the account — so a card labelled "Codex Pro 5X"
                    // that is really on Plus says so at a glance.
                    if let planName = account.plan {
                        PlanBadge(plan: planName, verbatim: true)
                    }
                    disclosure(expanded)
                    Spacer(minLength: 4)
                    Text(displayPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(PFont.display(14, .bold))
                        .foregroundStyle(band == .full ? Color.pfInk : tint)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                expanded
                    ? "Hide \(account.label) details" : "Show \(account.label) details")
            EnergyBar(fraction: (displayPercent ?? 0) / 100, color: tint, height: 12)
            // Reset timing stays visible when collapsed — one line, and without it
            // a red "93%" tells you you're nearly out but not when it comes back.
            if let subtitle = codexSubtitle(account) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            if expanded {
                Group {
                    if let resets = account.balances.first(where: { $0.id == "usage-resets" }) {
                        CodexUsageResetsView(resets: resets, now: now)
                    }
                }
                .popoverDisclosure(id: cardID)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func codexDisplayPercent(_ window: UsageWindow?) -> Double? {
        window?.displayPercent(showUsage: showsUsage)
    }

    private func codexSubtitle(_ account: ProviderAccountSnapshot) -> String? {
        var parts: [String] = []
        if let secondary = account.windows.first(where: { $0.id == "secondary" }),
            let percent = codexDisplayPercent(secondary)
        {
            let modeLabel = showsUsage ? "used" : "left"
            parts.append("\(secondary.title) \(Int(percent.rounded()))% \(modeLabel)")
        }
        if let credits = account.balances.first(where: { $0.id == "credits" }) {
            if credits.displayText == "Unlimited" {
                parts.append("Unlimited credits")
            } else if let remaining = credits.value, remaining > 0 {
                let formatted =
                    Self.codexCreditsFormatter.string(from: NSDecimalNumber(decimal: remaining))
                    ?? "\(remaining)"
                parts.append("\(formatted) credits")
            }
        }
        if let reset = account.windows.first(where: { $0.id == "primary" })?.resetAt,
            let phrase = ResetPhrase.spoken(until: reset, asOf: now)
        {
            parts.append("Resets \(phrase)")
        }
        if let resets = account.balances.first(where: { $0.id == "usage-resets" }) {
            parts.append(
                "\(resets.value.map { NSDecimalNumber(decimal: $0).intValue } ?? 0) usage resets available"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static var codexCreditsFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }

    // MARK: - Grok card (usage-based, local to the popover)

    @ViewBuilder
    private func grokNotices() -> some View {
        if appState.grokError != nil {
            noticeBanner(
                appState.grokError ?? "Grok refresh failed — showing last known data",
                systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if appState.grokIsStale {
            noticeBanner("Grok data may be outdated", systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    private func grokCard(_ account: ProviderAccountSnapshot) -> some View {
        let window = account.windows.first
        let displayPercent = window?.displayPercent(showUsage: showsUsage)
        let band = EnergyBand(severity: window?.severity(thresholds: usageThresholds) ?? .unknown)
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        let expanded = isExpanded(Self.grokCardID)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleCard(Self.grokCardID)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "atom")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(tint)
                    Text("Grok")
                        .font(PFont.display(14, .semibold))
                        .foregroundStyle(Color.pfInk)
                    disclosure(expanded)
                    Spacer()
                    Text(displayPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(PFont.display(14, .bold))
                        .foregroundStyle(band == .full ? Color.pfInk : tint)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide Grok details" : "Show Grok details")
            EnergyBar(fraction: (displayPercent ?? 0) / 100, color: tint, height: 12)
            if let subtitle = Self.grokSubtitle(account, asOf: now) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    static func grokSubtitle(_ account: ProviderAccountSnapshot, asOf now: Date) -> String? {
        var parts = account.windows.first.map { [$0.title] } ?? []
        if let balance = account.balances.first(where: { $0.id == "on-demand" }),
            let used = balance.value, used > 0
        {
            if let cap = balance.limit, cap > 0 {
                parts.append("On-demand \(dollars(used)) of \(dollars(cap))")
            } else {
                parts.append("On-demand \(dollars(used))")
            }
        }
        if let reset = account.windows.first?.resetAt,
            let phrase = ResetPhrase.spoken(until: reset, asOf: now)
        {
            parts.append("Resets \(phrase)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Simple depleting/filling capsule bar with an inner top gloss.
    // MARK: - Non-data states

    private func statusState(
        emoji: String, title: String, message: String,
        primaryTitle: String? = nil, primary: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Text(emoji).font(.system(size: 40))
            Text(title)
                .font(PFont.display(16, .semibold))
                .foregroundStyle(Color.pfInk)
            Text(message)
                .font(PFont.body(12, .semibold))
                .foregroundStyle(Color.pfInkMuted)
                .multilineTextAlignment(.center)
            if let primaryTitle, let primary {
                Button(primaryTitle, action: primary)
                    .buttonStyle(RaisedButtonStyle())
                    .fixedSize()
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 22)
    }

    private var onboardingContent: some View {
        statusState(
            emoji: "🚀",
            title: "Welcome to Claude Meter",
            message: "Connect a data source to start your engines.",
            primaryTitle: "Get started →",
            primary: openSettingsAndCompleteOnboarding)
    }

    private var inactiveState: some View {
        statusState(
            emoji: "😴", title: "Paused",
            message: "Hit play below to refuel the gauge.")
    }

    private var noSourcesState: some View {
        statusState(
            emoji: "🔌", title: "No data methods on",
            message: "Turn on at least one method in Settings → Data.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(0.9)
            Text(loadingMessage)
                .font(PFont.body(13, .semibold))
                .foregroundStyle(Color.pfInkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var loadingMessage: String {
        if AppSettings.oauthSourceEnabled
            && (cursorSourceEnabled || codexSourceEnabled || grokSourceEnabled)
        {
            return "Checking your tanks…"
        }
        if codexSourceEnabled && !AppSettings.oauthSourceEnabled && !cursorSourceEnabled {
            return "Checking Codex…"
        }
        if grokSourceEnabled && !AppSettings.oauthSourceEnabled && !cursorSourceEnabled
            && !codexSourceEnabled
        {
            return "Checking Grok…"
        }
        if cursorSourceEnabled && !AppSettings.oauthSourceEnabled { return "Checking Cursor…" }
        return "Checking your tanks…"
    }

    private var setupState: some View {
        statusState(emoji: "🪫", title: "No usage yet", message: setupMessage)
    }

    private var setupMessage: String {
        if codexSourceEnabled && !AppSettings.oauthSourceEnabled && !cursorSourceEnabled {
            return "Install Codex or run `codex login` so Claude Meter can read Codex usage."
        }
        if cursorSourceEnabled && !AppSettings.oauthSourceEnabled && !codexSourceEnabled {
            return "Sign in to the Cursor app so Claude Meter can read your billing usage."
        }
        if AppSettings.oauthSourceEnabled && (cursorSourceEnabled || codexSourceEnabled) {
            return "Open Claude Code, sign in to enabled sources, or connect OAuth in Settings."
        }
        return
            "Connect Claude OAuth in Settings to read your usage."
    }

    private var mainMeterErrorState: some View {
        statusState(
            emoji: "⚠️",
            title: "Couldn't read \(selectedProvider.displayName)",
            message: appState.mainMeterError ?? "Open Settings and check the selected meter.",
            primaryTitle: "Open Settings",
            primary: openSettingsAndCompleteOnboarding)
    }

    private var cursorErrorState: some View {
        statusState(
            emoji: "⚠️", title: "Couldn't read Cursor",
            message: appState.cursorError ?? "Open Cursor and try again.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }

    private var codexErrorState: some View {
        let error = appState.codexAccounts.compactMap(\.lastError).first
        return statusState(
            emoji: "⚠️", title: "Couldn't read Codex",
            message: error ?? "Install Codex or run `codex login`.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }

    private var grokErrorState: some View {
        statusState(
            emoji: "⚠️", title: "Couldn't read Grok",
            message: appState.grokError ?? "Install Grok Build or run `grok login`.",
            primaryTitle: "Open Settings", primary: openSettingsAndCompleteOnboarding)
    }

    private var errorState: some View {
        statusState(
            emoji: "⚠️", title: errorTitle, message: errorHint ?? "Check Diagnostics for details.",
            primaryTitle: shouldOfferSettings ? "Open Settings" : nil,
            primary: shouldOfferSettings ? { openSettingsAndCompleteOnboarding() } : nil)
    }

    // MARK: - Notices

    private func noticeBanner(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .bold))
            Text(text).font(PFont.body(11, .semibold)).lineLimit(3)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.13)))
    }

    private var updateAvailableNotice: some View {
        Button {
            appState.checkForUpdates()
        } label: {
            noticeBanner(
                "Update available — click to install", systemImage: "arrow.down.circle.fill",
                tint: .pfEnergyFull)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 15)
        .padding(.bottom, 2)
    }

    private var pollErrorText: String {
        let err = appState.lastError ?? ""
        if let issue = appState.oauthCredentialIssue {
            return issue.displayText(retryAt: appState.oauthRetryAt, now: now)
        }
        if err.contains("decode") || err.contains("data couldn't be read") {
            return "Refresh failed — could not parse usage data"
        }
        return "Refresh failed — showing last known data"
    }

    // MARK: - Footer

    private func squareButton(
        _ symbol: String, help: String, tint: Color = .pfInkMuted, size: CGFloat = 40,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .chunkyCard(radius: size * 0.3)
        .help(help)
    }

    private var updatedText: String {
        Self.updatedText(lastPollAt: appState.mainMeterLastSuccessfulAt, now: now)
    }

    nonisolated static func updatedText(lastPollAt: Date?, now: Date) -> String {
        guard let polledAt = lastPollAt else {
            return "Not yet polled"
        }
        // No "Updated " prefix: the header is width-bound at 360pt once the title
        // is held to one line, and the prefix was ~55pt that pushed this label into
        // truncation ("Updated 12s a…"). A bare relative time is unambiguous beside
        // a live meter, and the label carries a tooltip.
        let elapsed = now.boundedNonnegativeElapsedSeconds(since: polledAt)
        if elapsed < 5 { return "Just now" }
        if elapsed < 60 { return "\(elapsed)s ago" }
        let mins = elapsed / 60
        return "\(mins)m ago"
    }

    // MARK: - Onboarding helpers

    private func openSettingsAndCompleteOnboarding() {
        hasCompletedOnboarding = true
        appState.completeOnboarding()
        openSettings()
    }

    // MARK: - Error helpers

    private var errorTitle: String {
        "Could not read Claude usage"
    }

    private var errorHint: String? {
        appState.oauthCredentialIssue?.displayText(retryAt: appState.oauthRetryAt, now: now)
    }

    private var shouldOfferSettings: Bool {
        appState.oauthCredentialIssue != nil || oauthMode.isEmpty
    }

}

#Preview {
    PopoverView().environmentObject(
        AppState(usageStore: UsageStore(providers: []), onboardingIsComplete: false))
}
