import Foundation
import MeterPlatform
import MeterTestSupport
import Testing

@MainActor @Suite struct PowerStateMonitorTests {
    private let center = NotificationCenter()
    private let reading = Locked(
        PowerStateMonitor.Reading(isLowPowerModeEnabled: false, thermalState: .nominal))

    private func monitor() -> PowerStateMonitor {
        let reading = reading
        return PowerStateMonitor(center: center) { reading.value }
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
        let value = PowerStateMonitor.Reading(
            isLowPowerModeEnabled: lowPower, thermalState: thermal)
        #expect(value.isConstrained == constrained)
    }

    @Test func eachNotificationReadsBothValuesAndReportsOnlyChanges() async {
        let monitor = monitor()
        var changes = 0
        monitor.onChange = { changes += 1 }
        set(lowPower: true)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        #expect(await waitUntil { monitor.isConstrained })
        // Heat while Low Power Mode is on changes nothing.
        set(thermal: .serious)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        set(lowPower: false, thermal: .nominal)
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        #expect(await waitUntil { !monitor.isConstrained })
        #expect(changes == 2)
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
