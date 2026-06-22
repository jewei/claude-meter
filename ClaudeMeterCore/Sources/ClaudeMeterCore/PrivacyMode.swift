import Foundation

public enum PrivacyMode: String, CaseIterable, Identifiable, Sendable {
    case full       = "full"
    case workSafe   = "workSafe"
    case minimal    = "minimal"
    case anonymous  = "anonymous"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full:      return "Full"
        case .workSafe:  return "Work-safe"
        case .minimal:   return "Minimal"
        case .anonymous: return "Anonymous"
        }
    }

    public var detail: String {
        switch self {
        case .full:      return "Shows session name, model, and account info"
        case .workSafe:  return "Shows model; hides account and session details"
        case .minimal:   return "Shows only percentages and reset times"
        case .anonymous: return "Hides all identifiers"
        }
    }

    public var showsModel: Bool {
        self == .full || self == .workSafe
    }

    public var showsSessionName: Bool {
        self == .full || self == .workSafe
    }

    public var showsAccountInfo: Bool {
        self == .full
    }

    public var showsCwd: Bool {
        self == .full
    }
}
