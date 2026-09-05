import ClaudeMeterCore
import Foundation

public protocol CodexUsageSourceFetching: Sendable {
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

    public func fetchUsage(mode: CodexSourceMode = .auto, now: Date = Date()) async throws
        -> CodexUsage
    {
        try Task.checkCancellation()
        switch mode {
        case .appServer:
            let usage = try await appServerSource.fetchUsage(now: now)
            try Task.checkCancellation()
            return usage
        case .directOAuth:
            let usage = try await oauthSource.fetchUsage(now: now)
            try Task.checkCancellation()
            return usage
        case .auto:
            do {
                let usage = try await appServerSource.fetchUsage(now: now)
                try Task.checkCancellation()
                return usage
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let appServerError = error
                try Task.checkCancellation()
                do {
                    let usage = try await oauthSource.fetchUsage(now: now)
                    try Task.checkCancellation()
                    return usage
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    throw Self.combinedFailure(
                        appServer: appServerError,
                        directOAuth: error)
                }
            }
        }
    }

    private static func combinedFailure(appServer: Error, directOAuth: Error) -> CodexUsageError {
        CodexUsageError.allSourcesFailed(
            appServer: errorText(appServer),
            directOAuth: errorText(directOAuth))
    }

    private static func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
