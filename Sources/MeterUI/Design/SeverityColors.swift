import MeterApp
import MeterDomain
import SwiftUI

/// Colors for a severity: green is full, orange is low, red is empty.
extension Severity {
    /// The bright color for rings, bars, and dots.
    var fill: Color {
        switch self {
        case .normal: Palette.energyFull
        case .warning: Palette.energyLow
        case .critical, .exhausted: Palette.energyEmpty
        case .unknown: Palette.energyUnknown
        }
    }

    /// The darker color for small values and status text.
    var ink: Color {
        switch self {
        case .normal: Palette.energyFullInk
        case .warning: Palette.energyLowInk
        case .critical, .exhausted: Palette.energyEmptyInk
        case .unknown: Palette.inkMuted
        }
    }

    /// Header numbers stay ink while energy is full, and take the energy ink otherwise.
    var headlineInk: Color {
        self == .normal ? Palette.ink : ink
    }
}

extension HeroModel.Tone {
    var colors: HeroColors {
        switch self {
        case .full: Palette.heroFull
        case .low: Palette.heroLow
        case .empty: Palette.heroEmpty
        case .neutral: Palette.heroNeutral
        }
    }
}

extension PlanBadge.Tier {
    var colors: BadgeColors {
        switch self {
        case .max: Palette.planMax
        case .pro: Palette.planPro
        case .free: Palette.planFree
        }
    }
}
