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

    public func fetchUsage(now: Date = Date()) async throws -> CodexUsage {
        try Task.checkCancellation()
        do {
            let usage = try await oauthSource.fetchUsage(now: now)
            try Task.checkCancellation()
            return usage
        } catch {
            try Task.checkCancellation()
            guard Self.canRecoverWithAppServer(error) else { throw error }
            let directError = error
            do {
                let usage = try await appServerSource.fetchUsage(now: now)
                try Task.checkCancellation()
                return usage
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CodexOAuthCredentialsError where error == .apiKeyOnly {
                try Task.checkCancellation()
                throw error
            } catch {
                try Task.checkCancellation()
                throw Self.combinedFailure(appServer: error, directOAuth: directError)
            }
        }
    }

    /// Recovery belongs to Codex. Transport/server failures cannot repair credentials.
    static func canRecoverWithAppServer(_ error: Error) -> Bool {
        if let credentialError = error as? CodexOAuthCredentialsError {
            switch credentialError {
            case .notFound, .missingTokens, .decodeFailed, .unreadable, .expiredAccessToken:
                return true
            case .apiKeyOnly:
                return false
            }
        }
        return (error as? CodexUsageError) == .loginRequired
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
