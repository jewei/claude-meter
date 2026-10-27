import Foundation
import MeterPlatform
import MeterTestSupport
import Testing

@MainActor @Suite struct PowerStateMonitorTests {
    private let center = NotificationCenter()
    private let reading = Locked(
        PowerStateMonitor.PowerState(isLowPowerModeEnabled: false, thermalState: .nominal))
    /// How often the monitor read the values.
    private let reads = Locked(0)

    private func monitor() -> PowerStateMonitor {
        let reading = reading
        let reads = reads
        return PowerStateMonitor(center: center) {
            reads.withLock { $0 += 1 }
            return reading.value
        }
    }

    private func set(lowPower: Bool? = nil, thermal: ProcessInfo.ThermalState? = nil) {
        reading.withLock { reading in
            if let lowPower { reading.isLowPowerModeEnabled = lowPower }
            if let thermal { reading.thermalState = thermal }
        }
    }

    @Test(arguments: [
        (false, ProcessInfo.ThermalState.nominal, false), (false, .fair, false),
        (false, .serious, true), (false, .critical, true), (true, .nominal, true),
    ])
    func strainIsLowPowerModeOrHeat(
        lowPower: Bool, thermal: ProcessInfo.ThermalState, constrained: Bool
    ) {
        let value = PowerStateMonitor.PowerState(
            isLowPowerModeEnabled: lowPower, thermalState: thermal)
        #expect(value.isConstrained == constrained)
    }

    /// Posts one notification and waits until the monitor read the values for it. The read and
    /// the callback run in one main-actor step, so the update is complete then.
    private func post(_ name: Notification.Name) async {
        let before = reads.value
        center.post(name: name, object: nil)
        #expect(await waitUntil { reads.value > before })
    }

    @Test func eachNotificationReadsBothValuesAndReportsOnlyChanges() async {
        let monitor = monitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        // Heat alone is strain, also on a power notification.
        set(thermal: .serious)
        await post(.NSProcessInfoPowerStateDidChange)
        #expect(monitor.isConstrained)
        #expect(changes == 1)
        // Low Power Mode while hot changes nothing.
        set(lowPower: true)
        await post(ProcessInfo.thermalStateDidChangeNotification)
        #expect(changes == 1)
        // Cooling while Low Power Mode is on changes nothing.
        set(thermal: .nominal)
        await post(ProcessInfo.thermalStateDidChangeNotification)
        #expect(changes == 1)
        set(lowPower: false)
        await post(.NSProcessInfoPowerStateDidChange)
        #expect(!monitor.isConstrained)
        #expect(changes == 2)
    }

    @Test func theFirstValueIsReadAtCreation() {
        set(lowPower: true)
        #expect(monitor().isConstrained)
    }

    @Test func aPostFromAnotherThreadArrivesOnTheMainActor() async {
        let monitor = monitor()
        var calledOnMain = false
        monitor.onChange = { calledOnMain = Thread.isMainThread }
        set(lowPower: true)
        let center = center
        await Task.detached {
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        }.value
        #expect(await waitUntil { monitor.isConstrained })
        #expect(calledOnMain)
    }
}
