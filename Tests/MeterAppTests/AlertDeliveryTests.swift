import Foundation
import MeterDomain
import MeterTestSupport
import Testing

@testable import MeterApp
@testable import MeterPlatform

/// `AppModel` with ``FakeNotificationPoster``: when evaluations run and what gets posted.
@MainActor
@Suite(.timeLimit(.minutes(1))) final class AlertDeliveryTests {
    private let claude = FakeUsageProvider(.claude)
    private let codex = FakeUsageProvider(.codex)
    private let directory: TemporaryDirectory

    init() throws {
        directory = try TemporaryDirectory()
    }

    deinit {
        directory.remove()
    }

    private func makeModel(
        poster: FakeNotificationPoster, configure: (inout Settings) -> Void = { _ in },
        limits: AlertCenter.Limits = AlertCenter.Limits()
    ) -> AppModel {
        var settings = Settings()
        settings.hasCompletedOnboarding = true
        settings.claude.connection = .automatic
        settings.codex.isEnabled = true
        configure(&settings)
        let defaults = MemoryStore()
        defaults.set(SettingsCodec.encode(settings), forKey: SettingsStore.storageKey)
        let store = UsageStore(providers: [claude, codex])
        store.setEnabled(settings.enabledProviders)
        return AppModel(
            settings: SettingsStore(store: defaults), usage: store, scheduler: nil,
            updater: DisabledUpdater(), logFile: LogFile(directory: directory.path("Logs")),
            notifications: poster, alertLimits: limits)
    }

    private func usage(
        _ provider: ProviderID, _ windows: [QuotaWindow], at date: Date = Date()
    ) -> ProviderUsage {
        let account = AccountUsage(
            id: provider == .claude ? "work" : "/codex", name: "work", windows: windows,
            observedAt: date, owner: .identity("a"))
        return ProviderUsage(provider: provider, accounts: [account])
    }

    private func window(
        _ used: Double, id: String = "session", resetsIn: TimeInterval = .hours(2),
        duration: TimeInterval? = nil
    ) -> QuotaWindow {
        QuotaWindow(
            id: id, title: "Session", kind: .session, usedPercent: used,
            resetsAt: Date().addingTimeInterval(resetsIn), duration: duration)
    }

    /// Publishes a reading, then lets the merged evaluation and its delivery finish.
    private func publish(
        _ model: AppModel, _ provider: ProviderID, _ windows: [QuotaWindow]
    ) async {
        let fake = provider == .claude ? claude : codex
        fake.enqueue(usage(provider, windows))
        let before = model.alerts.evaluationCount
        await model.usage.refresh([provider])
        #expect(await waitUntil { model.alerts.evaluationCount > before })
        await model.alerts.latestDelivery?.value
    }

    /// Starts the model, and lets the evaluation that the first permission read schedules
    /// finish, so it does not count as the evaluation of the first publish.
    private func start(_ model: AppModel) async {
        await model.start(archive: nil)
        if model.alerts.authorization == .authorized {
            #expect(await waitUntil { model.alerts.evaluationCount >= 1 })
        }
    }

    /// Lets a settings change reach its evaluation and delivery.
    private func settle(_ model: AppModel) async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        await model.alerts.latestDelivery?.value
    }

    @Test func limitsMatchThePlan() {
        #expect(AlertCenter.authorizationLimit == .seconds(5))
        #expect(AlertCenter.postLimit == .seconds(5))
        #expect(AlertCenter.requestLimit == .seconds(600))
    }

    @Test func aCrossingPostsOnce() async throws {
        let poster = FakeNotificationPoster()
        let model = makeModel(poster: poster) { $0.alerts.lowEnergy = true }
        await start(model)
        await publish(model, .claude, [window(50)])
        await publish(model, .claude, [window(96)])
        await publish(model, .claude, [window(97)])
        #expect(poster.posted.map(\.title) == ["Low energy"])
        let id = try #require(poster.posted.first?.id)
        // A digest: macOS stores the ID, and a Codex account ID is a path with the user name.
        #expect(id.count == 64 && !id.contains("work"))
    }

    @Test func oneEvaluationPostsEveryAlertItOwes() async {
        let poster = FakeNotificationPoster()
        let model = makeModel(poster: poster) { $0.alerts.lowEnergy = true }
        await start(model)
        await publish(model, .claude, [window(50), window(50, id: "weekly")])
        await publish(model, .claude, [window(96), window(96, id: "weekly")])
        #expect(poster.posted.count == 2)
    }

    /// A relaunch with the kind already on is a baseline, so nothing posts.
    @Test func aRelaunchStaysSilent() async {
        let poster = FakeNotificationPoster()
        let model = makeModel(poster: poster) { $0.alerts.lowEnergy = true }
        await start(model)
        await publish(model, .claude, [window(96)])
        #expect(poster.attempts.isEmpty)
    }

    @Test func aFailedPostIsNotRetried() async {
        let poster = FakeNotificationPoster()
        poster.setAcceptsPosts(false)
        let model = makeModel(poster: poster) { $0.alerts.lowEnergy = true }
        await start(model)
        await publish(model, .claude, [window(50)])
        await publish(model, .claude, [window(96)])
        await publish(model, .claude, [window(97)])
        #expect(poster.attempts.count == 1)
        #expect(poster.posted.isEmpty)
    }

    @Test func aPostThatNeverAnswersTimesOutAndIsNotRetried() async {
        let poster = FakeNotificationPoster(postGate: Gate())
        var limits = AlertCenter.Limits()
        limits.post = .milliseconds(50)
        let model = makeModel(
            poster: poster, configure: { $0.alerts.lowEnergy = true }, limits: limits)
        await start(model)
        await publish(model, .claude, [window(50)])
        await publish(model, .claude, [window(96)])
        await publish(model, .claude, [window(97)])
        #expect(poster.attempts.count == 1)
    }

    @Test func anAuthorizationReadThatNeverAnswersTimesOut() async {
        let poster = FakeNotificationPoster(authorizationGate: Gate())
        var limits = AlertCenter.Limits()
        limits.authorization = .milliseconds(50)
        let model = makeModel(poster: poster, limits: limits)
        await start(model)
        #expect(model.alerts.authorization == nil)
    }

    /// Without permission nothing is evaluated, so the alert for turning the kind on is still
    /// owed after the grant. The prompt waits longer than the 5 s of other calls.
    @Test func theTurnedOnAlertWaitsForPermission() async {
        let request = Gate()
        let poster = FakeNotificationPoster(authorization: .notDetermined, requestGate: request)
        let model = makeModel(poster: poster)
        await start(model)
        await publish(model, .claude, [window(96)])
        model.settings.update { $0.alerts.lowEnergy = true }
        #expect(await request.waitForArrivals())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(poster.attempts.isEmpty)
        request.open()
        #expect(await waitUntil { poster.posted.count == 1 })
        #expect(poster.requests == 1)
    }

    @Test func aDeniedRequestPostsNothing() async {
        let poster = FakeNotificationPoster(authorization: .notDetermined)
        poster.setGrantsRequest(false)
        let model = makeModel(poster: poster)
        await start(model)
        await publish(model, .claude, [window(96)])
        model.settings.update { $0.alerts.lowEnergy = true }
        #expect(await waitUntil { model.alerts.authorization == .denied })
        await settle(model)
        #expect(poster.attempts.isEmpty)
        #expect(
            AlertPermissionText.notice(
                model.alerts.authorization, alerts: model.settings.settings.alerts)
                == "Notifications are off for Claude Meter. Turn them on in System Settings > "
                + "Notifications.")
    }

    /// Restored readings are never fresh. The activation waits for each provider's first
    /// publish, also when the providers publish at different times.
    @Test func anActivationWaitsForEachProvidersFirstPublish() async {
        let poster = FakeNotificationPoster()
        let model = makeModel(poster: poster)
        model.usage.restore([.claude: usage(.claude, [window(96)])])
        await start(model)
        model.settings.update { $0.alerts.lowEnergy = true }
        await settle(model)
        #expect(poster.attempts.isEmpty)
        await publish(model, .claude, [window(96)])
        #expect(poster.posted.count == 1)
        await publish(model, .codex, [window(97)])
        #expect(poster.posted.count == 2)
        await publish(model, .codex, [window(98)])
        #expect(poster.posted.count == 2)
    }

    @Test func turningRunOutOnPostsWithoutARefresh() async {
        let poster = FakeNotificationPoster()
        let model = makeModel(poster: poster)
        await start(model)
        // 2 hours into a 5-hour window: 60% runs out before the reset.
        await publish(model, .claude, [window(60, resetsIn: .hours(3), duration: .hours(5))])
        model.settings.update { $0.alerts.runOut = true }
        #expect(await waitUntil { poster.posted.count == 1 })
        #expect(poster.posted.first?.title == "Runs out before the reset")
    }

    @Test func turningAKindOffDropsItsActivation() async {
        let poster = FakeNotificationPoster()
        let model = makeModel(poster: poster)
        model.usage.restore([.claude: usage(.claude, [window(96)])])
        await start(model)
        model.settings.update { $0.alerts.lowEnergy = true }
        model.settings.update { $0.alerts.lowEnergy = false }
        model.settings.update { $0.alerts.refill = true }
        await publish(model, .claude, [window(96)])
        #expect(poster.attempts.isEmpty)
        #expect(model.alerts.state.activations[.lowEnergy] == nil)
    }

    /// Two changes in one main-actor turn give one evaluation, and one post.
    @Test func changesInOneTurnMerge() async {
        let poster = FakeNotificationPoster()
        let model = makeModel(poster: poster) { $0.alerts.lowEnergy = true }
        await start(model)
        await publish(model, .claude, [window(70)])
        let before = model.alerts.evaluationCount
        model.alerts.scheduleEvaluation()
        model.alerts.scheduleEvaluation()
        model.settings.update { $0.appearance.thresholds = Thresholds(warning: 50, critical: 60) }
        #expect(await waitUntil { model.alerts.evaluationCount > before })
        await settle(model)
        #expect(model.alerts.evaluationCount == before + 1)
        #expect(poster.posted.count == 1)
    }

    /// The popover does not make the app active, so a grant in System Settings is noticed
    /// when an evaluation finds no permission.
    @Test func aLaterGrantIsNoticedAtTheNextRefresh() async {
        let poster = FakeNotificationPoster(authorization: .denied)
        let model = makeModel(poster: poster) { $0.alerts.lowEnergy = true }
        await start(model)
        await publish(model, .claude, [window(50)])
        poster.setAuthorization(.authorized)
        await publish(model, .claude, [window(50)])
        #expect(await waitUntil { model.alerts.authorization == .authorized })
        await settle(model)
        await publish(model, .claude, [window(96)])
        #expect(poster.posted.count == 1)
    }

    /// A source turned off and on while macOS blocks notifications still forgets its state.
    @Test func turningASourceOffForgetsItsStateWithoutPermission() async {
        let poster = FakeNotificationPoster()
        let model = makeModel(poster: poster) { $0.alerts.lowEnergy = true }
        await start(model)
        await publish(model, .codex, [window(50)])
        #expect(model.alerts.state.windows.keys.contains { $0.provider == .codex })
        poster.setAuthorization(.denied)
        await model.alerts.refreshAuthorization()
        model.settings.update { $0.codex.isEnabled = false }
        #expect(!model.alerts.state.windows.keys.contains { $0.provider == .codex })
    }

    /// A queued alert whose switch was turned off while an earlier post waited is dropped.
    @Test func aQueuedAlertOfAKindTurnedOffIsDropped() async {
        let gate = Gate()
        let poster = FakeNotificationPoster(postGate: gate)
        let model = makeModel(poster: poster) { $0.alerts.lowEnergy = true }
        await start(model)
        await publish(model, .claude, [window(50), window(50, id: "weekly")])
        poster.setAcceptsPosts(true)
        let crossing = Task {
            await self.publish(model, .claude, [window(96), window(96, id: "weekly")])
        }
        #expect(await gate.waitForArrivals())
        model.settings.update { $0.alerts.lowEnergy = false }
        gate.open()
        await crossing.value
        #expect(poster.attempts.count == 1)
    }

    /// An older permission read that answers late does not overwrite a newer one.
    @Test func aLatePermissionReadDoesNotWin() async {
        let poster = FakeNotificationPoster(authorization: .denied)
        let model = makeModel(poster: poster)
        await start(model)
        let gate = Gate()
        poster.holdNextAuthorization(gate)
        let older = Task { await model.alerts.refreshAuthorization() }
        #expect(await gate.waitForArrivals())
        poster.setAuthorization(.authorized)
        await model.alerts.refreshAuthorization()
        gate.open()
        await older.value
        #expect(model.alerts.authorization == .authorized)
    }

    /// Settings saved by 4.1.2 have no alerts, and decode with every alert off.
    @Test func olderSettingsDecodeWithAlertsOff() {
        let json = #"{"hasCompletedOnboarding":true,"isPaused":false}"#
        let settings = SettingsCodec.decode(Data(json.utf8))
        #expect(settings.alerts == AlertSettings())
        #expect(settings.alerts.enabledKinds.isEmpty)
    }
}
