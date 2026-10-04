import Darwin
import Foundation
import MeterTestSupport
import Testing

@testable import ProviderCodex

/// A fake `codex` for the live recovery: a `/bin/sh` script that logs each request line,
/// writes its PID, its environment, and its arguments, and answers by method.
///
/// The live recovery gets no install folders, so a real `codex` is never found or started.
struct FakeCodexCLI {
    /// An `account/read` reply with a notification and a server request before the answer.
    static let accountReply = """
        printf '%s\\n' '{"method":"account/updated","params":{}}' '{"id":2,"method":"server/request","params":{}}' '{"id":2,"result":{"account":{"type":"chatgpt","email":"me@example.com","planType":"plus"}}}'
        """
    static let rateLimitsReply = """
        printf '%s\\n' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":22,"windowDurationMins":300}}}}'
        """
    /// An interpreter name that no real `PATH` folder holds.
    static let interpreterName = "claude-meter-fake-node"

    let root: TemporaryDirectory
    /// The command that the search finds, through `CODEX_CLI_PATH`.
    let executable: URL
    let home: CodexHome

    /// `prelude` runs before the request loop; `epilogue` runs after stdin closes.
    init(
        accountReply: String = accountReply, rateLimitsReply: String = rateLimitsReply,
        initializeReply: String? = nil, prelude: String = "", epilogue: String = ""
    ) throws {
        root = try TemporaryDirectory()
        home = CodexHome(directory: try root.makeDirectory("home"), isImplicit: true)
        executable = try root.write(
            Self.script(
                in: root, accountReply: accountReply, rateLimitsReply: rateLimitsReply,
                initializeReply: initializeReply, prelude: prelude, epilogue: epilogue),
            to: "bin/codex")
        #expect(chmod(executable.path, 0o755) == 0)
    }

    /// A launcher like an npm or bun install: the command at `command` is a link to
    /// `<prefix>/lib/node_modules/@openai/codex/bin/codex.js`, which starts with
    /// `#!/usr/bin/env <interpreter>`. The interpreter is the protocol script in `<prefix>/bin`.
    init(launcherAt command: String) throws {
        root = try TemporaryDirectory()
        home = CodexHome(directory: try root.makeDirectory("home"), isImplicit: true)
        let interpreter = try root.write(
            Self.script(
                in: root, accountReply: Self.accountReply, rateLimitsReply: Self.rateLimitsReply,
                initializeReply: nil, prelude: "", epilogue: ""),
            to: "prefix/bin/\(Self.interpreterName)")
        #expect(chmod(interpreter.path, 0o755) == 0)
        let launcher = try root.write(
            "#!/usr/bin/env \(Self.interpreterName)\n",
            to: "prefix/lib/node_modules/@openai/codex/bin/codex.js")
        #expect(chmod(launcher.path, 0o755) == 0)
        executable = root.path(command)
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: launcher)
    }

    private static func script(
        in root: TemporaryDirectory, accountReply: String, rateLimitsReply: String,
        initializeReply: String?, prelude: String, epilogue: String
    ) -> String {
        let initialize =
            initializeReply
            ?? #"printf '%s\n' 'not json' '{"id":1,"result":{"userAgent":"codex"}}'"#
        return """
            #!/bin/sh
            echo $$ > '\(root.path("pid").path)'
            printf '%s|%s|%s\\n' "${OPENAI_API_KEY-unset}" "$CODEX_HOME" "$PATH" > '\(root.path("env").path)'
            printf '%s\\n' "$*" > '\(root.path("args").path)'
            \(prelude)
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> '\(root.path("requests.log").path)'
              case "$line" in
                *'"method":"initialize"'*)
                  \(initialize) ;;
                *'"method":"account/read"'*)
                  \(accountReply) ;;
                *'"method":"account/rateLimits/read"'*)
                  \(rateLimitsReply) ;;
              esac
            done
            \(epilogue)
            """
    }

    /// The app environment with a short `PATH`, like a Finder launch, and a key to scrub.
    var environment: [String: String] {
        CodexEnvironment.scoped(
            [
                "CODEX_CLI_PATH": executable.path, "OPENAI_API_KEY": "sk-secret",
                "PATH": "/usr/bin:/bin",
            ],
            home: home)
    }

    /// The live recovery with no install folders, so a real `codex` is never found.
    /// `networkStepLimit` defaults to `stepLimit`.
    func server(
        stepLimit: Duration = .seconds(5), networkStepLimit: Duration? = nil
    ) -> CodexAppServer {
        CodexAppServer(
            installFolders: [], stepLimit: stepLimit,
            networkStepLimit: networkStepLimit ?? stepLimit)
    }

    func requests() -> [String] {
        let text = (try? String(contentsOf: root.path("requests.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func file(_ name: String) -> String {
        ((try? String(contentsOf: root.path(name), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waits up to 10 seconds until `condition` holds. Polls, so it does not depend on how
    /// fast a busy machine starts the child.
    func wait(until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Waits until the child has logged a request that contains `text`.
    func waitForRequest(containing text: String) async -> Bool {
        await wait { requests().contains { $0.contains(text) } }
    }

    /// The child no longer exists: it was stopped and reaped.
    func childIsGone() -> Bool {
        guard let pid = Int32(file("pid")) else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }
}
