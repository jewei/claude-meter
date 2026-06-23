import Foundation

public struct OAuthCredentials: Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    /// True when the access token is expired or within 60 s of expiry.
    public var isExpired: Bool {
        Date().timeIntervalSince(expiresAt) > -60
    }
}

/// Reads and writes the `claudeAiOauth` block inside Claude Code's Keychain entry.
///
/// Claude Code stores credentials under:
///   service = "Claude Code-credentials", account = current username
///
/// The `-a $(whoami)` flag is required — without it the correct entry is not found.
public enum OAuthKeychain: Sendable {

    private static let service = "Claude Code-credentials"

    /// Matches `$(whoami)` — required as the Keychain account for Claude Code's entry.
    private static var claudeCodeAccount: String { NSUserName() }

    public static func load() -> OAuthCredentials? {
        parse(findClaudeCodeCredentialsJSON())
    }

    /// Writes updated tokens back to the existing Keychain entry, preserving all other fields.
    /// Best-effort: silently ignores failures.
    public static func save(_ credentials: OAuthCredentials) {
        guard let current = findClaudeCodeCredentialsJSON(),
              let data = current.data(using: .utf8),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        var oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = credentials.accessToken
        oauth["refreshToken"] = credentials.refreshToken
        oauth["expiresAt"] = credentials.expiresAt.timeIntervalSince1970 * 1000
        json["claudeAiOauth"] = oauth
        guard let updated = try? JSONSerialization.data(withJSONObject: json),
              let updatedStr = String(data: updated, encoding: .utf8) else {
            return
        }
        // -U: update if entry already exists
        updateClaudeCodeCredentialsJSON(updatedStr)
    }

    // MARK: - Claude Code keychain access

    /// `security find-generic-password -s 'Claude Code-credentials' -a "$(whoami)" -w`
    private static func findClaudeCodeCredentialsJSON() -> String? {
        let account = claudeCodeAccount
        guard !account.isEmpty else { return nil }
        return runSecurity([
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w",
        ])
    }

    /// `security add-generic-password -U -s 'Claude Code-credentials' -a "$(whoami)" -w …`
    private static func updateClaudeCodeCredentialsJSON(_ json: String) {
        let account = claudeCodeAccount
        guard !account.isEmpty else { return }
        runSecurity([
            "add-generic-password",
            "-U",
            "-s", service,
            "-a", account,
            "-w", json,
        ])
    }

    // MARK: - Helpers

    /// Exposed for unit tests.
    internal static func parseForTesting(_ jsonString: String?) -> OAuthCredentials? {
        parse(jsonString)
    }

    private static func parse(_ jsonString: String?) -> OAuthCredentials? {
        guard let str = jsonString,
              let data = str.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty,
              let expiresAtMs = numericValue(oauth["expiresAt"])
        else { return nil }
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAtMs / 1000)
        )
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: nil
        }
    }

    // MARK: - App-owned manual token storage

    private static let manualService = "com.jewei.claudemeter-oauth"
    private static let manualAccount = "oauthManual"

    public static func loadManual() -> OAuthCredentials? {
        let json = runSecurity(["find-generic-password", "-s", manualService, "-a", manualAccount, "-w"])
        return parse(json)
    }

    public static func saveManual(accessToken: String, refreshToken: String) {
        let expiry = Date.distantFuture.timeIntervalSince1970 * 1000
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": accessToken,
                "refreshToken": refreshToken,
                "expiresAt": expiry
            ] as [String: Any]
        ]), let str = String(data: data, encoding: .utf8) else { return }
        runSecurity(["add-generic-password", "-U", "-s", manualService, "-a", manualAccount, "-w", str])
    }

    public static func deleteManual() {
        runSecurity(["delete-generic-password", "-s", manualService, "-a", manualAccount])
    }

    // MARK: - Helpers

    @discardableResult
    private static func runSecurity(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
