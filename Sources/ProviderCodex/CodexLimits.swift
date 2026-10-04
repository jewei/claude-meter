/// Time and concurrency limits of the Codex provider. Tests shorten them.
struct CodexLimits: Sendable {
    /// One deadline for a whole fetch, including home resolution.
    var fetch: Duration = .seconds(60)
    /// Home resolution and the local checks of `reconcile`.
    var homeResolution: Duration = .seconds(5)
    /// One read of `auth.json`.
    var fileRead: Duration = .seconds(5)
    /// The optional reset-credit details request.
    var resetDetails: Duration = .seconds(4)
    /// The local steps of app-server recovery: the executable search and `initialize`.
    var appServerStep: Duration = .seconds(5)
    /// The app-server steps that reach the network: `account/read`, which renews the token,
    /// and `account/rateLimits/read`. With the local steps, recovery stays within 41 seconds,
    /// inside the fetch deadline.
    var appServerNetworkStep: Duration = .seconds(15)
    /// Homes that refresh at the same time.
    var concurrentHomes = 3

    static let standard = CodexLimits()
}
