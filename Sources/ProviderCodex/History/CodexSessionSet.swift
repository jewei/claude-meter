import Foundation
import MeterPlatform

/// The sessions of one account, with each session counted once.
///
/// Codex can keep a session in `sessions` and a copy in `archived_sessions`. A copy that
/// continues the other, with the same ownership, replaces it. Copies that disagree make the
/// history partial, and the copy with more events is kept; with equal counts the copy that
/// was inserted first stays, so the result follows the root and path order.
struct CodexSessionSet {
    private var sessions: [String: CodexSessionLog] = [:]
    private(set) var isPartial = false

    /// Adds the session of the file at `path`. A file without a session ID is its own session.
    mutating func insert(_ session: CodexSessionLog, path: String) {
        let key = session.sessionID.map { "id:\($0)" } ?? "path:\(path)"
        guard let existing = sessions[key] else {
            sessions[key] = session
            return
        }
        let sameOwnership = session.hasSameOwnership(as: existing)
        if sameOwnership, session.events.starts(with: existing.events) {
            sessions[key] = session
        } else if !sameOwnership || !existing.events.starts(with: session.events) {
            isPartial = true
            if session.events.count > existing.events.count { sessions[key] = session }
        }
    }

    /// The records that each session owns. A fork finds its parent only in this set.
    func ownedRecords() -> (records: [TokenRecord], isPartial: Bool) {
        var records: [TokenRecord] = []
        var isPartial = self.isPartial
        for session in sessions.values {
            let parent = session.parentID.flatMap { sessions["id:\($0)"] }
            let owned = session.ownedRecords(parent: parent)
            records += owned.records
            isPartial = isPartial || owned.isPartial
        }
        return (records, isPartial)
    }
}
