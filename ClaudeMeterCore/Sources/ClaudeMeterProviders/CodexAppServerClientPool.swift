import ClaudeMeterCore
import Foundation

/// Keeps one initialized `codex app-server` process per Codex home, so a poll
/// pays for two JSON-RPC requests instead of a process spawn, an `initialize`
/// handshake, and a reap.
///
/// `CodexUsageProvider` is built per account per poll, so the reuse cannot live
/// in the provider or the source. It lives here, at process scope, keyed by the
/// resolved Codex home.
///
/// Reuse is a cache of a *process*, so correctness comes from the restart rules,
/// not from the caching. A pooled client is discarded when any of these change or
/// fail, and a fresh one is started in its place:
///
/// 1. The home's credential identity. A live app-server holds its sign-in in
///    memory, so without this check it can answer with the previous account after
///    the user signs in again. `SPECS.md` section 5.2 requires the owner to be
///    checked before a result is published.
/// 2. The resolved `codex` executable. A resident process keeps running the
///    binary it started with, so an upgrade must not be served by the old one.
/// 3. The child exited.
/// 4. The last use threw. A timed-out or cancelled request can leave an unread
///    response in the stream, which would desynchronize the next request.
/// The app's entry point for ending pooled provider subprocesses.
///
/// The pool itself stays internal: only the provider layer may start a process.
/// The app may only ask for them to stop.
public enum CodexSubprocesses {
    /// Ends every resident `codex app-server`. Safe to call repeatedly, and safe
    /// to call while a poll is in flight: that poll's request fails and its client
    /// is discarded rather than reused.
    public static func shutdownAll() async {
        await CodexAppServerClientPool.shared.shutdownAll()
    }
}

actor CodexAppServerClientPool {
    static let shared = CodexAppServerClientPool()

    /// How long an unused client stays resident. A home that stops polling must
    /// not keep a process alive for the life of the app.
    static let idleTimeout: TimeInterval = 10 * 60

    /// The identity of the executable a pooled client started with.
    ///
    /// Resolved through the symbolic link, because a package manager usually
    /// upgrades by repointing a link such as `/opt/homebrew/bin/codex`.
    struct ExecutableIdentity: Equatable, Sendable {
        let path: String
        let fileNumber: Int
        let size: Int
        let modifiedAt: Date

        init?(path: String) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
                let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue,
                let size = (attributes[.size] as? NSNumber)?.intValue,
                let modifiedAt = attributes[.modificationDate] as? Date
            else { return nil }
            self.path = resolved
            self.fileNumber = fileNumber
            self.size = size
            self.modifiedAt = modifiedAt
        }
    }

    private struct Entry {
        let client: CodexAppServerClient
        let credentialIdentity: CodexCredentialIdentity
        let executableIdentity: ExecutableIdentity?
        var lastUsedAt: Date
    }

    private var entries: [String: Entry] = [:]
    /// Counts started processes. Tests assert against it; production ignores it.
    private(set) var launchCount = 0

    /// Runs `body` against an initialized client for `home`.
    ///
    /// The client is reused when every restart rule still holds. Any error from
    /// `body`, including cancellation, discards the client before it rethrows.
    func withClient<T: Sendable>(
        home: String,
        executable: String,
        env: [String: String],
        startupTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        credentialIdentity: CodexCredentialIdentity,
        now: Date = Date(),
        body: @Sendable (CodexAppServerClient) async throws -> T
    ) async throws -> T {
        await evictIdleEntries(now: now)
        let executableIdentity = ExecutableIdentity(path: executable)
        let client = try await reusableClient(
            home: home,
            executable: executable,
            env: env,
            startupTimeout: startupTimeout,
            requestTimeout: requestTimeout,
            credentialIdentity: credentialIdentity,
            executableIdentity: executableIdentity,
            now: now)

        do {
            let value = try await body(client)
            entries[home]?.lastUsedAt = Date()
            return value
        } catch {
            // Rule 4. The stream may hold an unread response, so this process can
            // never serve another request.
            await discard(home: home)
            throw error
        }
    }

    /// Ends every pooled process. Called when the app pauses, the display sleeps,
    /// or the app terminates.
    func shutdownAll() async {
        let live = entries
        entries.removeAll()
        for entry in live.values {
            await entry.client.shutdown()
        }
    }

    func shutdown(home: String) async {
        await discard(home: home)
    }

    func resetForTesting() async {
        await shutdownAll()
        launchCount = 0
    }

    /// The number of homes holding a resident process.
    var residentHomeCount: Int { entries.count }

    func evictIdleEntriesForTesting(now: Date) async {
        await evictIdleEntries(now: now)
    }

    /// Ends the pooled child without telling the pool, which is what an outside
    /// kill or a crash looks like.
    func killPooledProcessForTesting(home: String) async {
        guard let entry = entries[home] else { return }
        await entry.client.shutdown()
    }

    // MARK: - Private

    private func reusableClient(
        home: String,
        executable: String,
        env: [String: String],
        startupTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        credentialIdentity: CodexCredentialIdentity,
        executableIdentity: ExecutableIdentity?,
        now: Date
    ) async throws -> CodexAppServerClient {
        if let existing = entries[home] {
            // Rules 1 to 3. An unreadable executable identity is treated as a
            // change, because it cannot prove the binary is the same one.
            let mayReuse =
                existing.credentialIdentity == credentialIdentity
                && existing.executableIdentity != nil
                && existing.executableIdentity == executableIdentity
                && existing.client.isAlive
            if mayReuse { return existing.client }
            await discard(home: home)
        }

        let client = try CodexAppServerClient(
            executable: executable,
            env: env,
            startupTimeout: startupTimeout,
            requestTimeout: requestTimeout)
        launchCount += 1
        do {
            try await client.initialize()
        } catch {
            await client.shutdown()
            throw error
        }
        entries[home] = Entry(
            client: client,
            credentialIdentity: credentialIdentity,
            executableIdentity: executableIdentity,
            lastUsedAt: now)
        return client
    }

    private func discard(home: String) async {
        guard let entry = entries.removeValue(forKey: home) else { return }
        await entry.client.shutdown()
    }

    private func evictIdleEntries(now: Date) async {
        let stale = entries.filter {
            now.timeIntervalSince($0.value.lastUsedAt) >= Self.idleTimeout
        }
        for home in stale.keys {
            await discard(home: home)
        }
    }
}
