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
    /// Each JSON-RPC step of app-server recovery.
    var appServerStep: Duration = .seconds(5)
    /// Homes that refresh at the same time.
    var concurrentHomes = 3

    static let standard = CodexLimits()
}
