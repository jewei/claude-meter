import MeterPlatform

/// Time and concurrency limits of the Codex provider. Tests shorten them.
struct CodexLimits: Sendable {
    /// One deadline for a whole fetch, including home resolution.
    var fetch: Duration = .seconds(60)
    /// Home resolution and the local checks of `reconcile`.
    var homeResolution: Duration = .seconds(5)
    /// One read of `auth.json`, a small local file.
    var fileRead: Duration = .seconds(3)
    /// The usage request.
    var usageRequest: Duration = .seconds(15)
    /// The optional reset-credit details request.
    var resetDetails: Duration = .seconds(4)
    /// The local steps of app-server recovery: the executable search and `initialize`.
    var appServerStep: Duration = .seconds(5)
    /// The app-server steps that reach the network: `account/read`, which renews the token,
    /// and `account/rateLimits/read`.
    var appServerNetworkStep: Duration = .seconds(10)
    /// Homes that refresh at the same time.
    var concurrentHomes = 3

    static let standard = CodexLimits()

    /// The longest refresh of one home that starts at once, home resolution included. It must
    /// fit ``fetch``, so a slow step ends with its own message, not with the fetch deadline.
    ///
    /// The slower path is a usage request that sends the login to recovery (HTTP 401 or 403),
    /// then the whole recovery: the search, `initialize`, both network steps, and the stop of
    /// the child (TERM, the grace period, KILL, and the wait for the reap). The auth file is
    /// read before and after.
    var worstCaseFetch: Duration {
        let direct = usageRequest + resetDetails
        let stop = LineProcess.terminationGrace + LineProcess.reapLimit
        let recovery = appServerStep * 2 + appServerNetworkStep * 2 + stop
        return homeResolution + fileRead * 2 + max(direct, usageRequest + recovery)
    }
}
