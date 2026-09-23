import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI

func sanitizeDiagnosticsForClipboard(_ text: String) -> String {
    DiagnosticsSanitizer.sanitize(text)
}

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    private var codexDiagnostics: [String: CodexSourceDiagnostic] {
        (appState.usageStore.provider(for: .codex) as? CodexProviderAdapter)?.sourceDiagnostics
            ?? [:]
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                dataSourceSection
                sourceAttemptsSection
                pollSection
                warningsSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Copy Sanitized Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        sanitizeDiagnosticsForClipboard(diagnosticsText), forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .buttonStyle(.borderless)

                Text(copied ? "Copied!" : "")
                    .font(.caption)
                    .foregroundStyle(Color.cmNormal)
                    .animation(reduceMotion ? nil : .easeOut, value: copied)

                Spacer()

                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var sourceAttemptsSection: some View {
        let attempts = appState.claudeDiagnostics.sourceAttempts
        if !attempts.isEmpty {
            Section("Source Attempts") {
                ForEach(Array(attempts.enumerated()), id: \.offset) { _, attempt in
                    Text(attempt.diagnosticDescription)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Sections

    private var dataSourceSection: some View {
        Section("Data Source") {
            LabeledContent("Mode", value: dataSourceMode)
            LabeledContent("Main meter") {
                Text(
                    [
                        appState.mainMeterProvider.displayName,
                        appState.mainMeterReading?.accountLabel,
                    ].compactMap { $0 }.joined(separator: " · "))
            }
            if AppSettings.cursorSourceEnabled {
                LabeledContent(
                    "Cursor", value: appState.cursorSnapshot != nil ? "Connected" : "Not available")
            }
            if AppSettings.codexSourceEnabled {
                ForEach(appState.codexAccounts) { reading in
                    LabeledContent(DiagnosticsSanitizer.sanitize(reading.label)) {
                        if let usage = codexDiagnostics[reading.id] {
                            Text(
                                [usage.source, usage.authentication]
                                    .compactMap { $0 }.joined(separator: " · "))
                        } else {
                            Text("Not available")
                        }
                    }
                }
            }
            if AppSettings.grokSourceEnabled {
                LabeledContent(
                    "Grok", value: appState.grokSnapshot != nil ? "Connected" : "Not available")
            }
            ForEach(appState.accountOAuthFailures.keys.sorted(), id: \.self) { accountKey in
                if let failure = appState.accountOAuthFailures[accountKey] {
                    LabeledContent("\(AppState.friendlyAccountName(accountKey)) OAuth") {
                        Text(accountOAuthFailureText(failure))
                            .foregroundStyle(Color.cmCritical)
                    }
                }
            }
        }
    }

    private var pollSection: some View {
        Section("Last Poll") {
            LabeledContent("Claude", value: claudePollTimeText)
            if let err = appState.lastError {
                LabeledContent("Claude error") {
                    Text(DiagnosticsSanitizer.sanitize(err))
                        .foregroundStyle(Color.cmCritical)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if AppSettings.cursorSourceEnabled {
                LabeledContent("Cursor", value: cursorPollTimeText)
                if let err = appState.cursorError {
                    LabeledContent("Cursor error") {
                        Text(DiagnosticsSanitizer.sanitize(err))
                            .foregroundStyle(Color.cmCritical)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            if AppSettings.codexSourceEnabled {
                ForEach(appState.codexAccounts) { reading in
                    LabeledContent(
                        "\(DiagnosticsSanitizer.sanitize(reading.label)) success",
                        value: reading.observedAt.map { isoFormatter.string(from: $0) }
                            ?? "Never"
                    )
                    LabeledContent(
                        "\(DiagnosticsSanitizer.sanitize(reading.label)) attempt",
                        value: reading.lastAttemptAt.map { isoFormatter.string(from: $0) }
                            ?? "None this launch"
                    )
                    if let err = reading.lastError {
                        LabeledContent(
                            "\(DiagnosticsSanitizer.sanitize(reading.label)) error"
                        ) {
                            Text(DiagnosticsSanitizer.sanitize(err))
                                .foregroundStyle(Color.cmCritical)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if AppSettings.grokSourceEnabled {
                LabeledContent("Grok", value: grokPollTimeText)
                if let err = appState.grokError {
                    LabeledContent("Grok error") {
                        Text(DiagnosticsSanitizer.sanitize(err))
                            .foregroundStyle(Color.cmCritical)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        let warnings = appState.claudeDiagnostics.warnings
        if !warnings.isEmpty {
            Section("Parser Warnings (\(warnings.count))") {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.field).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(DiagnosticsSanitizer.sanitize(w.message))
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Helpers

    private var claudePollTimeText: String {
        guard let date = appState.lastPolledAt else {
            return "Never"
        }
        return isoFormatter.string(from: date)
    }

    private var cursorPollTimeText: String {
        guard let date = appState.cursorLastPolledAt else { return "Never" }
        return isoFormatter.string(from: date)
    }

    private var grokPollTimeText: String {
        guard let date = appState.grokLastPolledAt else { return "Never" }
        return isoFormatter.string(from: date)
    }

    private var dataSourceMode: String {
        "OAuth usage API"
    }

    private static nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var isoFormatter: ISO8601DateFormatter { Self.isoFormatter }

    // MARK: - Copy text

    private var diagnosticsText: String {
        var lines: [String] = [
            "=== Claude Meter Diagnostics (sanitized) ===",
            "Generated: \(isoFormatter.string(from: Date()))",
            "",
            "Data Source",
            "  Mode: \(dataSourceMode)",
            "  Main meter: \(appState.mainMeterProvider.displayName)",
            "  Main account: \(DiagnosticsSanitizer.sanitize(appState.mainMeterReading?.accountLabel ?? "Unavailable"))",
            "  Main error: \(DiagnosticsSanitizer.sanitize(appState.mainMeterError ?? "None"))",
            "",
            "Last Poll",
            "  Claude: \(claudePollTimeText)",
            "  Claude error: \(DiagnosticsSanitizer.sanitize(appState.lastError ?? "None"))",
        ]
        if AppSettings.cursorSourceEnabled {
            lines += [
                "  Cursor: \(cursorPollTimeText)",
                "  Cursor error: \(DiagnosticsSanitizer.sanitize(appState.cursorError ?? "None"))",
            ]
        }
        if AppSettings.codexSourceEnabled {
            for reading in appState.codexAccounts {
                let success =
                    reading.observedAt.map { isoFormatter.string(from: $0) } ?? "Never"
                let attempt =
                    reading.lastAttemptAt.map { isoFormatter.string(from: $0) }
                    ?? "None this launch"
                lines += [
                    "  Codex account: \(DiagnosticsSanitizer.sanitize(reading.label))",
                    "    Home: \(DiagnosticsSanitizer.sanitize(reading.id))",
                    "    Last success: \(success)",
                    "    Last attempt: \(attempt)",
                    "    Source: \(codexDiagnostics[reading.id]?.source ?? "None")",
                    "    Auth: \(codexDiagnostics[reading.id]?.authentication ?? "Unknown")",
                    "    Error: \(DiagnosticsSanitizer.sanitize(reading.lastError ?? "None"))",
                ]
            }
        }
        if AppSettings.grokSourceEnabled {
            lines += [
                "  Grok: \(grokPollTimeText)",
                "  Grok error: \(DiagnosticsSanitizer.sanitize(appState.grokError ?? "None"))",
            ]
        }
        for accountKey in appState.accountOAuthFailures.keys.sorted() {
            guard let failure = appState.accountOAuthFailures[accountKey] else { continue }
            lines.append(
                "  \(AppState.friendlyAccountName(accountKey)) OAuth: \(accountOAuthFailureText(failure))"
            )
        }
        lines += [""]

        let attempts = appState.claudeDiagnostics.sourceAttempts
        if !attempts.isEmpty {
            lines.append("Source Attempts")
            lines += attempts.map { "  \($0.diagnosticDescription)" }
            lines.append("")
        }

        let warnings = appState.claudeDiagnostics.warnings
        if !warnings.isEmpty {
            lines.append("Parser Warnings")
            for w in warnings {
                let msg = DiagnosticsSanitizer.sanitize(w.message)
                lines.append("  [\(w.field)] \(msg)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func accountOAuthFailureText(
        _ failure: MultiAccountOAuth.AccountFetchFailure
    ) -> String {
        switch failure {
        case .credentialsMissing: "Credentials missing"
        case .credentialsUnavailable: "Keychain unavailable"
        case .credentialsInvalid: "Credentials invalid"
        case .credentialsExpired: "Credentials expired"
        case .unauthorized: "Unauthorized"
        case .rateLimited: "Rate limited"
        case .invalidResponse: "Invalid response"
        case .requestFailed: "Request failed"
        }
    }
}
