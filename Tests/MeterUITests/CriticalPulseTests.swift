import Foundation
import MeterApp
import MeterDomain
import Testing

@testable import MeterUI

@Suite struct CriticalPulseTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    /// Updates `pulse` and returns whether a pulse started.
    private func start(
        _ pulse: inout CriticalPulse, icon: MenuBarModel.Icon, now: Date, reduceMotion: Bool
    ) -> Bool {
        pulse.update(icon: icon, now: now, reduceMotion: reduceMotion)
    }

    @Test func pulsesWhenTheBadgeBecomesCritical() {
        var pulse = CriticalPulse()
        #expect(!start(&pulse, icon: .bolt(.dot(.warning)), now: now, reduceMotion: false))
        #expect(start(&pulse, icon: .bolt(.dot(.critical)), now: now, reduceMotion: false))
        #expect(pulse.isRunning(at: now.addingTimeInterval(3.5)))
        #expect(!pulse.isRunning(at: now.addingTimeInterval(3.6)))
        #expect(pulse.runningStart(at: now.addingTimeInterval(4)) == nil)
    }

    @Test func aLastingCriticalStateDoesNotPulseAgain() {
        var pulse = CriticalPulse()
        pulse.update(icon: .bolt(.dot(.critical)), now: now, reduceMotion: false)
        let later = now.addingTimeInterval(60)
        #expect(!start(&pulse, icon: .bolt(.dot(.critical)), now: later, reduceMotion: false))
        #expect(!pulse.isRunning(at: later))
    }

    @Test func loadingStaleAndErrorPeriodsDoNotRestartIt() {
        var pulse = CriticalPulse()
        pulse.update(icon: .bolt(.dot(.critical)), now: now, reduceMotion: false)
        for icon in [MenuBarModel.Icon.loading, .bolt(.stale), .error] {
            #expect(!start(&pulse, icon: icon, now: now, reduceMotion: false))
            #expect(!start(&pulse, icon: .bolt(.dot(.critical)), now: now, reduceMotion: false))
        }
    }

    @Test func aNewDropToCriticalPulsesAgain() {
        var pulse = CriticalPulse()
        pulse.update(icon: .bolt(.dot(.critical)), now: now, reduceMotion: false)
        pulse.update(icon: .bolt(.dot(.normal)), now: now, reduceMotion: false)
        #expect(start(&pulse, icon: .bolt(.dot(.critical)), now: now, reduceMotion: false))
    }

    @Test func reduceMotionNeverPulses() {
        var pulse = CriticalPulse()
        #expect(!start(&pulse, icon: .bolt(.dot(.critical)), now: now, reduceMotion: true))
        #expect(!pulse.isRunning(at: now))
    }

    @Test func phaseRisesToOneMidCycleAndRestsOutside() {
        #expect(CriticalPulse.phase(elapsed: 0) == 0)
        #expect(abs(CriticalPulse.phase(elapsed: 0.6) - 1) < 0.000_1)
        #expect(CriticalPulse.phase(elapsed: -1) == 0)
        #expect(CriticalPulse.phase(elapsed: 3.6) == 0)
        #expect(CriticalPulse.scale(phase: 1) == 1.35)
        #expect(abs(CriticalPulse.opacity(phase: 1) - 0.55) < 0.000_1)
    }
}
