import Foundation
import MeterDomain

/// A folder whose local session records count toward one account, such as a Claude config
/// dir or a Codex home. The folder sets the scope: its records can include earlier logins
/// that used it. Records never decide which account they belong to.
public struct HistoryRoot: Hashable, Sendable {
    public let account: AccountID
    public let directory: URL

    public init(account: AccountID, directory: URL) {
        self.account = account
        self.directory = directory
    }
}
