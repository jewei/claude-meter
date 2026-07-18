import ClaudeMeterCore
import Foundation

public protocol CodexUsageSourceFetching: Sendable {
    func isAvailable() async -> Bool
    func fetchUsage(now: Date) async throws -> CodexUsage
}

public final class CodexUsageProvider: @unchecked Sendable {
    private let appServerSource: any CodexUsageSourceFetching
    private let oauthSource: any CodexUsageSourceFetching

    public init(
        appServerSource: any CodexUsageSourceFetching = CodexAppServerSource(),
        oauthSource: any CodexUsageSourceFetching = CodexDirectOAuthSource()
    ) {
        self.appServerSource = appServerSource
        self.oauthSource = oauthSource
    }

    public convenience init(codexHome: URL) {
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome.path
        let scopedEnv = env
        self.init(
            appServerSource: CodexAppServerSource(env: scopedEnv),
            oauthSource: CodexDirectOAuthSource(credentialsLoader: {
                try CodexOAuthCredentialsStore.load(env: scopedEnv)
            }))
    }

    public func fetchUsage(mode: CodexSourceMode = .auto, now: Date = Date()) async throws -> CodexUsage {
        switch mode {
        case .appServer:
            return try await fetchRequired(appServerSource, now: now)
        case .directOAuth:
            return try await fetchRequired(oauthSource, now: now)
        case .auto:
            if await appServerSource.isAvailable() {
                do {
                    return try await appServerSource.fetchUsage(now: now)
                } catch {
                    if !Self.shouldTryOAuth(afterAppServerError: error) { throw error }
                    return try await fetchOAuthIfAvailable(now: now, preferredError: error)
                }
            }
            return try await fetchOAuthIfAvailable(now: now, preferredError: CodexUsageError.cliNotFound)
        }
    }

    private func fetchRequired(_ source: any CodexUsageSourceFetching, now: Date) async throws -> CodexUsage {
        guard await source.isAvailable() else {
            if source is CodexUnavailableSource { throw CodexUsageError.noUsageData }
            throw CodexUsageError.sourceUnavailable
        }
        return try await source.fetchUsage(now: now)
    }

    private func fetchOAuthIfAvailable(now: Date, preferredError: Error) async throws -> CodexUsage {
        guard await oauthSource.isAvailable() else { throw preferredError }
        do {
            return try await oauthSource.fetchUsage(now: now)
        } catch {
            throw preferredError
        }
    }

    private static func shouldTryOAuth(afterAppServerError error: Error) -> Bool {
        switch error {
        case CodexUsageError.cliNotFound, CodexUsageError.loginRequired:
            return true
        default:
            return false
        }
    }
}

public struct CodexUnavailableSource: CodexUsageSourceFetching {
    let error: Error

    public init(error: Error) {
        self.error = error
    }

    public func isAvailable() async -> Bool { false }
    public func fetchUsage(now _: Date) async throws -> CodexUsage { throw error }
}
