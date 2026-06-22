import Foundation

enum PrivacyMode: String, CaseIterable, Identifiable {
    case full       = "full"
    case workSafe   = "workSafe"
    case minimal    = "minimal"
    case anonymous  = "anonymous"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full:      return "Full"
        case .workSafe:  return "Work-safe"
        case .minimal:   return "Minimal"
        case .anonymous: return "Anonymous"
        }
    }

    var detail: String {
        switch self {
        case .full:      return "Shows session name, model, and account info"
        case .workSafe:  return "Shows model; hides account and session details"
        case .minimal:   return "Shows only percentages and reset times"
        case .anonymous: return "Hides all identifiers"
        }
    }

    // Whether the active model row should be visible
    var showsModel: Bool {
        self == .full || self == .workSafe
    }

    // Whether session name should be visible (full and work-safe per SPECS §13.1)
    var showsSessionName: Bool {
        self == .full || self == .workSafe
    }

    var showsAccountInfo: Bool {
        self == .full
    }

    var showsCwd: Bool {
        self == .full
    }
}
