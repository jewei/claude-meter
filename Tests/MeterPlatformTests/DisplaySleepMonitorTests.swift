import AppKit
import MeterPlatform
import Testing

@MainActor @Suite struct DisplaySleepMonitorTests {
    private let center = NotificationCenter()

    private func post(_ name: Notification.Name) {
        center.post(name: name, object: nil)
    }

    @Test func reportsOneSleepAndOneWake() {
        let monitor = DisplaySleepMonitor(center: center)
        var events: [String] = []
        monitor.onSleep = { events.append("sleep") }
        monitor.onWake = { events.append("wake") }

        post(NSWorkspace.screensDidWakeNotification)
        #expect(events.isEmpty)
        post(NSWorkspace.screensDidSleepNotification)
        post(NSWorkspace.screensDidSleepNotification)
        #expect(monitor.isDisplayAsleep)
        // Screens and system both report the wake.
        post(NSWorkspace.screensDidWakeNotification)
        post(NSWorkspace.didWakeNotification)
        #expect(!monitor.isDisplayAsleep)
        #expect(events == ["sleep", "wake"])
    }

    @Test func aSystemWakeEndsADisplaySleep() {
        let monitor = DisplaySleepMonitor(center: center)
        post(NSWorkspace.screensDidSleepNotification)
        post(NSWorkspace.didWakeNotification)
        #expect(!monitor.isDisplayAsleep)
    }
}
