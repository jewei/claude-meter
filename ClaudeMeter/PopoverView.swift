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
    @AppStorage(AppGroupConfig.cardStyleKey) private var cardStyle = "rings"
    @AppStorage(AppGroupConfig.progressionModeKey) private var progressionMode = "left"
    @AppStorage(AppGroupConfig.mainMeterProviderKey) private var mainMeterProvider = "claude"
    @AppStorage(AppSettings.oauthModeKey) private var oauthMode = ""
    @State private var now = Date()
    @State private var showHeatmap = false
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
    private var cardStyleValue: AppGroupConfig.CardStyle {
        AppGroupConfig.CardStyle(rawValue: cardStyle) ?? .rings
    }

    nonisolated static func accountCardStyle(
        requested: AppGroupConfig.CardStyle,
        provider: MainMeterProvider
    ) -> AppGroupConfig.CardStyle {
        switch provider {
        case .claude, .codex: requested
        }
    }

    private var showsUsage: Bool {
        (AppGroupConfig.ProgressionMode(rawValue: progressionMode) ?? .left) == .used
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
                    if showHeatmap {
                        heatmapBody
                    } else {
                        if appState.updateAvailable {
                            updateAvailableNotice
                        }
                        if selectedProvider == .claude,
                            let status = appState.serviceStatus,
                            status.level.isIncident
                        {
                            serviceStatusNotice(status)
                        }
                        mainContent
                    }
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
        // The popover view is retained across dismissals (MenuBarExtra `.window`),
        // so reset to the main view on close — otherwise reopening lands on the
        // heatmap and skips onboarding/error/loading branches.
        .onDisappear {
            isVisible = false
            showHeatmap = false
            // Don't keep burning disk I/O on a heatmap nobody is looking at.
            appState.cancelActivityHeatmapLoad()
        }
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
                Text(updatedText)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Last updated")
            }
            // Settings and Quit moved up from the footer, which is now gone.
            // Refresh went with it: `popoverDidOpen()` already refreshes on every
            // open, so the button only re-did what had just happened.
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
        cursorSourceEnabled && appState.cursorUsage != nil
    }

    private var hasCodex: Bool {
        codexSourceEnabled && appState.codexAccounts.contains { $0.usage != nil }
    }

    private var hasGrok: Bool {
        grokSourceEnabled && appState.grokUsage != nil
    }

    private var hasAnyData: Bool {
        appState.snapshot != nil || hasCursor || hasCodex || hasGrok
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
            if hasCursor, let cursor = appState.cursorUsage {
                cursorNotices()
                cursorCard(cursor)
            }
            if hasGrok, let grok = appState.grokUsage {
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
        if let snap = appState.snapshot, AppSettings.hasClaudeSource {
            let models = accountModels(snap)
            if isPrimary {
                claudeNotices(snap)
                if appState.mainMeterReading == nil {
                    selectedMeterUnavailable(provider: .claude)
                } else {
                    HeroView(
                        summary: appState.mainMeterIsStale
                            ? HeroSummary.stale(
                                providerName: "Claude",
                                recovery: oauthMode.isEmpty
                                    ? "Open Claude Code or connect OAuth"
                                    : "Claude data is out of date"
                            )
                            : HeroSummary.make(
                                models: primaryOrdered(models),
                                thresholds: usageThresholds,
                                now: now))
                }
                accountsSection(primaryOrdered(models))
                if let extra = snap.limits.extraUsage, extra.hasSpend {
                    extraUsageCard(extra)
                }
                if !snap.models.isEmpty {
                    costCard(snap.models)
                } else {
                    activityEntryCard
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
                    hasError: orderedCodexReadings.contains(where: { $0.error != nil }),
                    isStale: orderedCodexReadings.contains(where: {
                        $0.observationIsStale(asOf: now)
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
                        if model.isLive { LiveDot() }
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
    private func claudeNotices(_ snap: ClaudeUsageSnapshot) -> some View {
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
        } else if appState.oauthEnrichmentIsStale {
            noticeBanner(
                "OAuth details may be outdated — showing last known values",
                systemImage: "clock.fill",
                tint: .pfInkMuted)
        }
        if appState.claudeIsStale || snap.state.isStale {
            let message =
                oauthMode.isEmpty
                ? "Claude data is stale — open Claude Code or connect OAuth in Settings"
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
        style: AppGroupConfig.CardStyle
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

    private var orderedCodexReadings: [CodexAccountReading] {
        let selectedID = selectedProvider == .codex ? appState.mainMeterReading?.accountID : nil
        return appState.codexAccounts.sorted { lhs, rhs in
            if lhs.id == selectedID { return true }
            if rhs.id == selectedID { return false }
            return lhs.account.displayName.localizedCaseInsensitiveCompare(rhs.account.displayName)
                == .orderedAscending
        }
    }

    private var codexAccountModels: [AccountCardModel] {
        orderedCodexReadings.compactMap(Self.codexAccountModel)
    }

    static func codexAccountModel(_ reading: CodexAccountReading) -> AccountCardModel? {
        guard let normalized = AppState.codexMainMeterReading(reading) else { return nil }
        var model = AccountCardModel(mainMeterReading: normalized)
        model.rateLimitResets = reading.usage?.rateLimitResets
        return model
    }

    /// Builds the unified per-account list: `snapshot.accounts` when present
    /// (active first), else a single card synthesized from the top-level snapshot.
    /// Plan/email/Opus come from OAuth and exist only for the active account.
    private func accountModels(_ snap: ClaudeUsageSnapshot) -> [AccountCardModel] {
        // "Live" = a Claude Code session is open right now: the snapshot came from
        // the statusline tier and isn't stale. OAuth-tier snapshots mean no open
        // CLI session, so no dot.
        let bridgeLive = snap.parserVersion.hasPrefix("statusline") && !appState.claudeIsStale
        if let accounts = snap.accounts, !accounts.isEmpty {
            let duplicates = MultiAccountOAuth.duplicateOrgAccountKeys(accounts)
            let sorted = accounts.sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            return sorted.map { acc in
                AccountCardModel(
                    id: acc.id,
                    label: AppGroupConfig.accountName(forKey: acc.id)
                        ?? acc.label.friendlyAccountLabel,
                    plan: AppGroupConfig.accountPlan(forKey: acc.id)
                        ?? (acc.isActive ? snap.account?.plan : acc.account?.plan)
                            ?? acc.account?.plan,
                    subtitle: (acc.isActive ? snap.account?.email : acc.account?.email)
                        ?? acc.account?.email,
                    session: acc.limits.currentSession,
                    week: acc.limits.currentWeekAllModels,
                    opus: acc.isActive
                        ? (snap.limits.currentWeekOpus ?? acc.limits.currentWeekOpus)
                        : acc.limits.currentWeekOpus,
                    scoped: Self.scopedLimits(for: acc, topLevel: snap.limits),
                    isDuplicateLogin: duplicates.contains(acc.id),
                    isLive: acc.isActive && bridgeLive
                )
            }
        }
        // Single-account override key must match how Settings stores it (the
        // discovery account key), not the OAuth email.
        let singleID = StatuslineBridge.defaultAccountKey
        return [
            AccountCardModel(
                id: singleID,
                label: AppGroupConfig.accountName(forKey: singleID) ?? "Claude",
                plan: AppGroupConfig.accountPlan(forKey: singleID) ?? snap.account?.plan,
                subtitle: snap.account?.email,
                session: snap.limits.currentSession,
                week: snap.limits.currentWeekAllModels,
                opus: snap.limits.currentWeekOpus,
                scoped: snap.limits.scopedWeekly ?? [],
                isLive: bridgeLive
            )
        ]
    }

    nonisolated static func scopedLimits(
        for account: AccountUsage,
        topLevel: LimitInfo
    ) -> [ScopedLimitWindow] {
        if account.isActive {
            return topLevel.scopedWeekly ?? account.limits.scopedWeekly ?? []
        }
        return account.limits.scopedWeekly ?? []
    }

    // MARK: - Extra usage (pay-as-you-go overage)

    private func extraUsageCard(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("💳").font(.system(size: 13))
                Text("Extra usage")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                if !extra.isEnabled {
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
            if let pct = extra.percentUsed {
                EnergyBar(fraction: min(1, pct / 100), color: .pfEnergyFull, height: 12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func extraUsageText(_ extra: ExtraUsage) -> String {
        let symbol = extra.currency == "USD" || extra.currency == nil ? "$" : "\(extra.currency!) "
        let used = String(format: "%@%.2f", symbol, extra.usedAmount ?? 0)
        if let limit = extra.limitAmount, limit > 0 {
            return used + String(format: " / %@%.2f", symbol, limit)
        }
        return used
    }

    // MARK: - Cost breakdown (local log scan, last 7 days)

    /// Opens the activity heatmap and kicks off (or refreshes) its scan.
    private func openHeatmap() {
        appState.loadActivityHeatmap()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showHeatmap = true }
    }

    /// Heatmap entry when there's no 7-day cost data (OAuth-only week, pricing
    /// miss, idle week) — so activity is still reachable whenever transcripts exist.
    private var activityEntryCard: some View {
        Button(action: openHeatmap) {
            HStack(spacing: 7) {
                Text("🗓️").font(.system(size: 13))
                Text("Activity")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                Spacer()
                Text("When you work")
                    .font(PFont.body(12, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .chunkyCard()
        }
        .buttonStyle(.plain)
        .help("View activity heatmap")
    }

    /// Single summary row. The per-model breakdown used to live here and was the
    /// tallest non-account card in the popover; the total is the number people
    /// come for, and the card is still the way into the activity heatmap — the
    /// only other entry point (`activityEntryCard`) appears solely when there's no
    /// cost data at all, so this must not become a plain label.
    private func costCard(_ models: [ModelUsage]) -> some View {
        let total = models.reduce(0.0) { $0 + ($1.costUsd ?? 0) }
        return Button(action: openHeatmap) {
            HStack(spacing: 7) {
                Text("💸").font(.system(size: 13))
                Text("Last 7 days")
                    .font(PFont.display(14, .semibold))
                    .foregroundStyle(Color.pfInk)
                if appState.costScanPartial {
                    Text("partial")
                        .font(PFont.body(10, .semibold))
                        .foregroundStyle(Color.pfInkMuted)
                }
                Spacer()
                Text(Self.usd(total))
                    .font(PFont.display(14, .bold))
                    .foregroundStyle(Color.pfInk)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .chunkyCard()
        }
        .buttonStyle(.plain)
        .help("View activity heatmap")
    }

    private static func usd(_ value: Double) -> String {
        value < 0.01 && value > 0 ? "<$0.01" : String(format: "$%.2f", value)
    }

    // MARK: - Activity heatmap (cost card flips to this)

    private var heatmapBody: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        showHeatmap = false
                    }
                    appState.cancelActivityHeatmapLoad()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text("Back").font(PFont.display(13, .semibold))
                    }
                    .foregroundStyle(Color.pfInk)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("🗓️").font(.system(size: 13))
                Text("Activity")
                    .font(PFont.display(15, .semibold))
                    .foregroundStyle(Color.pfInk)
            }
            heatmapCard
        }
        .padding(.horizontal, 15)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let map = appState.activityHeatmap, !map.isEmpty {
                Text(heatmapSubtitle(map))
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
                ActivityHeatmapGrid(map: map)
                heatmapLegend
            } else if appState.activityHeatmapLoading {
                heatmapPlaceholder("Scanning your activity…", loading: true)
            } else {
                heatmapPlaceholder("No activity in the last 30 days")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func heatmapPlaceholder(_ text: String, loading: Bool = false) -> some View {
        VStack(spacing: 10) {
            if loading {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(PFont.body(12, .semibold))
                .foregroundStyle(Color.pfInkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private func heatmapSubtitle(_ map: ActivityHeatmap) -> String {
        var parts = ["\(map.total) messages · last 30 days"]
        if map.daysCovered > 0, map.daysCovered < 30 {
            parts = ["\(map.total) messages · \(map.daysCovered) active days"]
        }
        if map.isPartial { parts.append("partial") }
        return parts.joined(separator: " · ")
    }

    private var heatmapLegend: some View {
        HStack(spacing: 5) {
            Text("Less").font(PFont.body(10, .semibold)).foregroundStyle(Color.pfInkMuted)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(ActivityHeatmapGrid.color(forLevel: level))
                    .frame(width: 11, height: 11)
            }
            Text("More").font(PFont.body(10, .semibold)).foregroundStyle(Color.pfInkMuted)
            Spacer()
        }
    }

    // MARK: - Cursor card (spend-based, shared left/used progression)

    private func cursorCard(_ cursor: CursorUsage) -> some View {
        let displayPercent = cursor.displayPercent(showUsage: showsUsage)
        let band = EnergyBand(severity: usageThresholds.severity(for: cursor.percentUsed))
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
                    if let planName = cursor.displayPlanName {
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
            if let subtitle = cursorSubtitle(cursor) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            if expanded {
                Group {
                    if cursor.clampedAutoPercent != nil || cursor.clampedAPIPercent != nil {
                        Divider().overlay(Color.pfCardBorder)
                        VStack(spacing: 7) {
                            if let percentUsed = cursor.clampedAutoPercent,
                                let displayedPercent = cursor.displayAutoPercent(
                                    showUsage: showsUsage)
                            {
                                cursorUsageRow(
                                    "Auto + Composer",
                                    percentUsed: percentUsed,
                                    displayedPercent: displayedPercent)
                            }
                            if let percentUsed = cursor.clampedAPIPercent,
                                let displayedPercent = cursor.displayAPIPercent(
                                    showUsage: showsUsage)
                            {
                                cursorUsageRow(
                                    "API",
                                    percentUsed: percentUsed,
                                    displayedPercent: displayedPercent)
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

    private func cursorSubtitle(_ usage: CursorUsage) -> String? {
        var parts: [String] = []
        if let spend = usage.spendText { parts.append("\(spend) spent") }
        if let end = usage.periodEnd, let phrase = ResetPhrase.spoken(until: end, asOf: now) {
            parts.append("Resets \(phrase)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Codex card (usage-based, local to the popover)

    @ViewBuilder
    private func codexAccountCard(
        _ reading: CodexAccountReading,
        style: AppGroupConfig.CardStyle
    ) -> some View {
        if style == .rings, let model = Self.codexAccountModel(reading) {
            AccountRingCard(
                model: model,
                now: now,
                thresholds: usageThresholds,
                usage: showsUsage)
        } else if let usage = reading.usage {
            codexCard(usage, account: reading.account)
        }
    }

    @ViewBuilder
    private func codexNotices(_ reading: CodexAccountReading) -> some View {
        if let error = reading.error {
            noticeBanner(
                "\(reading.account.displayName): \(error)",
                systemImage: "exclamationmark.triangle.fill", tint: .pfEnergyLow)
        } else if reading.observationIsStale(asOf: now) {
            noticeBanner(
                "\(reading.account.displayName) data may be outdated",
                systemImage: "clock.fill", tint: .pfInkMuted)
        }
    }

    private func codexCard(_ usage: CodexUsage, account: CodexAccount) -> some View {
        let primary = usage.primaryWindow
        let percentUsed = primary?.usedPercent
        let displayPercent = codexDisplayPercent(primary)
        let band = EnergyBand(severity: usageThresholds.severity(for: percentUsed))
        let tint: Color = band == .full ? .pfEnergyFull : band.color
        let cardID = Self.codexCardID(account.id)
        let expanded = isExpanded(cardID)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleCard(cardID)
            } label: {
                HStack(spacing: 7) {
                    codexMark
                    Text(account.displayName)
                        .font(PFont.display(14, .semibold))
                        .foregroundStyle(Color.pfInk)
                        .lineLimit(1)
                    // The plan the provider actually reports, beside the name the
                    // user gave the account — so a card labelled "Codex Pro 5X"
                    // that is really on Plus says so at a glance.
                    if let planName = usage.displayPlanName {
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
                    ? "Hide \(account.displayName) details" : "Show \(account.displayName) details")
            EnergyBar(fraction: (displayPercent ?? 0) / 100, color: tint, height: 12)
            // Reset timing stays visible when collapsed — one line, and without it
            // a red "93%" tells you you're nearly out but not when it comes back.
            if let subtitle = codexSubtitle(usage) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
            if expanded {
                Group {
                    if let resets = usage.rateLimitResets {
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

    private func codexDisplayPercent(_ window: CodexLimitWindow?) -> Double? {
        window?.displayPercent(showUsage: showsUsage)
    }

    private func codexSubtitle(_ usage: CodexUsage) -> String? {
        var parts: [String] = []
        if let secondary = usage.secondaryWindow,
            let percent = codexDisplayPercent(secondary)
        {
            let modeLabel = showsUsage ? "used" : "left"
            parts.append("\(secondary.displayLabel) \(Int(percent.rounded()))% \(modeLabel)")
        }
        if let credits = usage.usageCredits {
            if credits.unlimited {
                parts.append("Unlimited credits")
            } else if credits.remaining > 0 {
                let formatted =
                    Self.codexCreditsFormatter.string(from: NSNumber(value: credits.remaining))
                    ?? "\(credits.remaining)"
                parts.append("\(formatted) credits")
            }
        }
        if let reset = usage.primaryWindow?.resetAt,
            let phrase = ResetPhrase.spoken(until: reset, asOf: now)
        {
            parts.append("Resets \(phrase)")
        }
        if let resets = usage.rateLimitResets {
            parts.append("\(resets.availableCount) usage resets available")
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

    private func grokCard(_ usage: GrokUsage) -> some View {
        let displayPercent = usage.displayPercent(showUsage: showsUsage)
        let band = EnergyBand(severity: usageThresholds.severity(for: usage.usedPercent))
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
                    Text("\(Int(displayPercent.rounded()))%")
                        .font(PFont.display(14, .bold))
                        .foregroundStyle(band == .full ? Color.pfInk : tint)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide Grok details" : "Show Grok details")
            EnergyBar(fraction: displayPercent / 100, color: tint, height: 12)
            if let subtitle = grokSubtitle(usage) {
                Text(subtitle)
                    .font(PFont.body(11, .semibold))
                    .foregroundStyle(Color.pfInkMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .chunkyCard()
    }

    private func grokSubtitle(_ usage: GrokUsage) -> String? {
        var parts: [String] = [usage.windowLabel]
        if usage.onDemandUsedCents > 0 {
            let used = Double(usage.onDemandUsedCents) / 100
            if usage.onDemandCapCents > 0 {
                let cap = Double(usage.onDemandCapCents) / 100
                parts.append(String(format: "On-demand $%.2f of $%.2f", used, cap))
            } else {
                parts.append(String(format: "On-demand $%.2f", used))
            }
        }
        if let reset = usage.resetsAt, let phrase = ResetPhrase.spoken(until: reset, asOf: now) {
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
        if AppSettings.hasClaudeSource
            && (cursorSourceEnabled || codexSourceEnabled || grokSourceEnabled)
        {
            return "Checking your tanks…"
        }
        if codexSourceEnabled && !AppSettings.hasClaudeSource && !cursorSourceEnabled {
            return "Checking Codex…"
        }
        if grokSourceEnabled && !AppSettings.hasClaudeSource && !cursorSourceEnabled
            && !codexSourceEnabled
        {
            return "Checking Grok…"
        }
        if cursorSourceEnabled && !AppSettings.hasClaudeSource { return "Checking Cursor…" }
        return "Checking your tanks…"
    }

    private var setupState: some View {
        statusState(emoji: "🪫", title: "No usage yet", message: setupMessage)
    }

    private var setupMessage: String {
        if codexSourceEnabled && !AppSettings.hasClaudeSource && !cursorSourceEnabled {
            return "Install Codex or run `codex login` so Claude Meter can read Codex usage."
        }
        if cursorSourceEnabled && !AppSettings.hasClaudeSource && !codexSourceEnabled {
            return "Sign in to the Cursor app so Claude Meter can read your billing usage."
        }
        if AppSettings.hasClaudeSource && (cursorSourceEnabled || codexSourceEnabled) {
            return "Open Claude Code, sign in to enabled sources, or connect OAuth in Settings."
        }
        return
            "Open Claude Code so the statusline bridge can publish usage, or connect OAuth in Settings."
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
        let error = appState.codexAccounts.compactMap(\.error).first
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

    private func serviceStatusNotice(_ status: ServiceStatus) -> some View {
        let tint: Color =
            status.level == .critical || status.level == .major ? .pfEnergyEmpty : .pfEnergyLow
        return noticeBanner(
            "Anthropic: \(status.description)", systemImage: "exclamationmark.bubble.fill",
            tint: tint
        )
        .padding(.horizontal, 15)
        .padding(.bottom, 2)
    }

    private var pollErrorText: String {
        let err = appState.lastError ?? ""
        if isSessionExpiredError(err) {
            return err
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

    private func isSessionExpiredError(_ err: String) -> Bool {
        err.localizedCaseInsensitiveContains("session expired")
            || err.localizedCaseInsensitiveContains("session key")
    }

    private var errorTitle: String {
        let err = appState.lastError ?? ""
        if isSessionExpiredError(err) {
            return "Session expired"
        }
        if err.contains("decode") || err.contains("data couldn't be read") {
            return "Could not parse usage data"
        }
        return "Could not read usage stats"
    }

    private var errorHint: String? {
        let err = appState.lastError ?? ""
        if isSessionExpiredError(err) {
            return "Update your session key and org ID in Settings → Data."
        }
        if err.contains("decode") {
            return "Check Diagnostics for details."
        }
        return nil
    }

    private var shouldOfferSettings: Bool {
        let err = appState.lastError ?? ""
        return err.localizedCaseInsensitiveContains("session")
            || err.localizedCaseInsensitiveContains("session key")
    }
}

// MARK: - Preview helpers

extension AppState {
    static var preview: AppState {
        let snap = ClaudeUsageSnapshot(
            parserVersion: "preview-1.0",
            createdAt: Date(),
            lastSuccessfulPollAt: Date(),
            source: SourceInfo(
                cliPath: "/Users/jewei/.claude/stats-cache.json", command: "stats-cache"),
            account: AccountInfo(email: "you@oneone.com", plan: "Max"),
            session: SessionInfo(activeModel: "claude-sonnet-4-6"),
            limits: LimitInfo(
                currentSession: LimitWindow(
                    percentUsed: 22,
                    resetsAt: Date().addingTimeInterval(3 * 3600 + 12 * 60),
                    rawValueText: "245 msgs"
                ),
                currentWeekAllModels: LimitWindow(
                    percentUsed: 36,
                    resetsAt: Calendar.current.startOfDay(
                        for: Date().addingTimeInterval(3 * 86400)),
                    rawValueText: "1482 msgs"
                )
            ),
            state: SnapshotState(status: .ok, severity: .normal)
        )
        let store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
        try? store.writeLatest(snap)
        let pipeline = CachedSnapshotPipeline(store: store)
        return AppState(pipeline: pipeline, initialSnapshot: snap)
    }

    /// Three-account sample mirroring the design mock (Work / Personal / buildbot).
    /// Percentages are stored as % *used*; the UI shows the inverse as energy left.
    static var previewMulti: AppState {
        func win(used: Double, hoursToReset: Double) -> LimitWindow {
            LimitWindow(percentUsed: used, resetsAt: Date().addingTimeInterval(hoursToReset * 3600))
        }
        let work = AccountUsage(
            id: "it-oneone", label: "it-oneone",
            account: AccountInfo(email: "you@oneone.com", plan: "Max"),
            limits: LimitInfo(
                currentSession: win(used: 18, hoursToReset: 3.2),
                currentWeekAllModels: win(used: 30, hoursToReset: 72),
                currentWeekOpus: win(used: 42, hoursToReset: 72)),
            severity: .normal, isActive: true)
        let personal = AccountUsage(
            id: "personal", label: "personal",
            account: AccountInfo(plan: "Pro"),
            limits: LimitInfo(
                currentSession: win(used: 84, hoursToReset: 1.8),
                currentWeekAllModels: win(used: 24, hoursToReset: 96)),
            severity: .warning, isActive: false)
        let buildbot = AccountUsage(
            id: "buildbot", label: "buildbot",
            account: AccountInfo(plan: "Free"),
            limits: LimitInfo(
                currentSession: win(used: 97, hoursToReset: 1.1),
                currentWeekAllModels: win(used: 86, hoursToReset: 120)),
            severity: .critical, isActive: false)
        let snap = ClaudeUsageSnapshot(
            parserVersion: "preview-multi",
            createdAt: Date(), lastSuccessfulPollAt: Date(),
            source: SourceInfo(cliPath: "statusline", command: "statusline"),
            account: AccountInfo(email: "you@oneone.com", plan: "Max"),
            limits: work.limits,
            state: SnapshotState(status: .ok, severity: .normal),
            accounts: [work, personal, buildbot])
        let store = SnapshotStore(directory: FileManager.default.temporaryDirectory)
        try? store.writeLatest(snap)
        return AppState(pipeline: CachedSnapshotPipeline(store: store), initialSnapshot: snap)
    }
}

#Preview("Single account") {
    PopoverView()
        .environmentObject(AppState.preview)
        .frame(width: 360)
}

#Preview("Multi-account") {
    PopoverView()
        .environmentObject(AppState.previewMulti)
        .frame(width: 360)
}
