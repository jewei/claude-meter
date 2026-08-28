import ClaudeMeterCore
import ClaudeMeterProviders
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                dataSourceSection
                sourceAttemptsSection
                pollSection
                snapshotSection
                warningsSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Copy Sanitized Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticsText, forType: .string)
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
                    .animation(.easeOut, value: copied)

                Spacer()

                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    @ViewBuilder
    private var sourceAttemptsSection: some View {
        if let attempts = appState.lastPollResult?.sourceAttempts, !attempts.isEmpty {
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
            if let snap = appState.snapshot {
                LabeledContent("Source", value: DiagnosticsSanitizer.sanitize(snap.source.command))
                LabeledContent("Parser", value: snap.parserVersion)
            }
            if AppSettings.cursorSourceEnabled {
                LabeledContent(
                    "Cursor", value: appState.cursorUsage != nil ? "Connected" : "Not available")
            }
            if AppSettings.codexSourceEnabled {
                LabeledContent("Codex mode", value: AppSettings.codexSourceMode.rawValue)
                ForEach(appState.codexAccounts) { reading in
                    LabeledContent(DiagnosticsSanitizer.sanitize(reading.account.displayName)) {
                        if let usage = reading.usage {
                            Text(
                                [usage.source.rawValue, usage.authMode?.rawValue]
                                    .compactMap { $0 }.joined(separator: " · "))
                        } else {
                            Text("Not available")
                        }
                    }
                }
            }
            if AppSettings.grokSourceEnabled {
                LabeledContent(
                    "Grok", value: appState.grokUsage != nil ? "Connected" : "Not available")
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
            if appState.oauthEnrichmentLastPolledAt != nil
                || appState.oauthEnrichmentError != nil
            {
                LabeledContent("OAuth details", value: oauthEnrichmentPollTimeText)
                if let err = appState.oauthEnrichmentError {
                    LabeledContent("OAuth details error") {
                        Text(DiagnosticsSanitizer.sanitize(err))
                            .foregroundStyle(Color.cmCritical)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
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
                        "\(DiagnosticsSanitizer.sanitize(reading.account.displayName)) success",
                        value: reading.lastSuccessfulAt.map { isoFormatter.string(from: $0) }
                            ?? "Never"
                    )
                    LabeledContent(
                        "\(DiagnosticsSanitizer.sanitize(reading.account.displayName)) attempt",
                        value: reading.lastAttemptAt.map { isoFormatter.string(from: $0) }
                            ?? "None this launch"
                    )
                    if let err = reading.error {
                        LabeledContent(
                            "\(DiagnosticsSanitizer.sanitize(reading.account.displayName)) error"
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

    private var snapshotSection: some View {
        Section("Snapshot") {
            LabeledContent(
                "Schema version", value: appState.snapshot.map { "\($0.schemaVersion)" } ?? "—")
            LabeledContent("Parser version", value: appState.snapshot?.parserVersion ?? "—")
            LabeledContent(
                "Created",
                value: appState.snapshot.map { isoFormatter.string(from: $0.createdAt) } ?? "—")
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        if let warnings = appState.lastPollResult?.warnings, !warnings.isEmpty {
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
        guard let date = appState.snapshot?.lastSuccessfulPollAt ?? appState.lastPolledAt else {
            return "Never"
        }
        return isoFormatter.string(from: date)
    }

    private var cursorPollTimeText: String {
        guard let date = appState.cursorLastPolledAt else { return "Never" }
        return isoFormatter.string(from: date)
    }

    private var oauthEnrichmentPollTimeText: String {
        guard let date = appState.oauthEnrichmentLastPolledAt else { return "Never" }
        let suffix = appState.oauthEnrichmentIsStale ? " (stale)" : ""
        return isoFormatter.string(from: date) + suffix
    }

    private var grokPollTimeText: String {
        guard let date = appState.grokLastPolledAt else { return "Never" }
        return isoFormatter.string(from: date)
    }

    private var dataSourceMode: String {
        let parserVersion = appState.snapshot?.parserVersion ?? ""
        if parserVersion.hasPrefix("statusline") { return "Statusline bridge" }
        if parserVersion.hasPrefix("oauth") { return "OAuth usage API" }
        return "Cached snapshot"
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
        if appState.oauthEnrichmentLastPolledAt != nil
            || appState.oauthEnrichmentError != nil
        {
            lines += [
                "  OAuth details: \(oauthEnrichmentPollTimeText)",
                "  OAuth details error: \(DiagnosticsSanitizer.sanitize(appState.oauthEnrichmentError ?? "None"))",
            ]
        }
        if AppSettings.cursorSourceEnabled {
            lines += [
                "  Cursor: \(cursorPollTimeText)",
                "  Cursor error: \(DiagnosticsSanitizer.sanitize(appState.cursorError ?? "None"))",
            ]
        }
        if AppSettings.codexSourceEnabled {
            lines.append("  Codex mode: \(AppSettings.codexSourceMode.rawValue)")
            for reading in appState.codexAccounts {
                let success =
                    reading.lastSuccessfulAt.map { isoFormatter.string(from: $0) } ?? "Never"
                let attempt =
                    reading.lastAttemptAt.map { isoFormatter.string(from: $0) }
                    ?? "None this launch"
                lines += [
                    "  Codex account: \(DiagnosticsSanitizer.sanitize(reading.account.displayName))",
                    "    Home: \(DiagnosticsSanitizer.sanitize(reading.account.home.path))",
                    "    Last success: \(success)",
                    "    Last attempt: \(attempt)",
                    "    Source: \(reading.usage?.source.rawValue ?? "None")",
                    "    Auth: \(reading.usage?.authMode?.rawValue ?? "Unknown")",
                    "    Error: \(DiagnosticsSanitizer.sanitize(reading.error ?? "None"))",
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

        if let attempts = appState.lastPollResult?.sourceAttempts, !attempts.isEmpty {
            lines.append("Source Attempts")
            lines += attempts.map { "  \($0.diagnosticDescription)" }
            lines.append("")
        }

        if let snap = appState.snapshot {
            lines += [
                "Snapshot",
                "  Schema version: \(snap.schemaVersion)",
                "  Parser version: \(snap.parserVersion)",
                "  Created: \(isoFormatter.string(from: snap.createdAt))",
            ]
            lines.append("  Source: \(DiagnosticsSanitizer.sanitize(snap.source.command))")
            lines.append("")
        }

        if let warnings = appState.lastPollResult?.warnings, !warnings.isEmpty {
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
