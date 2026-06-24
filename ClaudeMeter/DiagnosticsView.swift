import SwiftUI
import ClaudeMeterCore

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                dataSourceSection
                pollSection
                snapshotSection
                warningsSection
            }
            .formStyle(.grouped)
            .onAppear {}

            Divider()

            HStack {
                Button("Copy Sanitized Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticsText, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
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

    // MARK: - Sections

    private var dataSourceSection: some View {
        Section("Data Source") {
            LabeledContent("Mode", value: dataSourceMode)
            if let snap = appState.snapshot {
                LabeledContent("Source", value: DiagnosticsSanitizer.sanitize(snap.source.command))
                LabeledContent("Parser", value: snap.parserVersion)
            }
            if AppSettings.cursorSourceEnabled {
                LabeledContent("Cursor", value: appState.cursorUsage != nil ? "Connected" : "Not available")
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
        }
    }

    private var snapshotSection: some View {
        Section("Snapshot") {
            LabeledContent("Schema version", value: appState.snapshot.map { "\($0.schemaVersion)" } ?? "—")
            LabeledContent("Parser version", value: appState.snapshot?.parserVersion ?? "—")
            LabeledContent("Created", value: appState.snapshot.map { isoFormatter.string(from: $0.createdAt) } ?? "—")
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

    private var dataSourceMode: String {
        let parserVersion = appState.snapshot?.parserVersion ?? ""
        if parserVersion.hasPrefix("statusline") { return "Statusline bridge" }
        if parserVersion.hasPrefix("oauth") { return "OAuth usage API" }
        if parserVersion.hasPrefix("claude-ai") { return "claude.ai API" }
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
        lines += [""]

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
}
