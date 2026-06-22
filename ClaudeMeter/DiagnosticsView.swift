import SwiftUI
import ClaudeMeterCore

/// Redacts sensitive identifiers from diagnostics text per SPECS §16.4.
enum DiagnosticsSanitizer {
    private static let emailPattern = #"[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#

    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(
            of: emailPattern,
            with: "[redacted]",
            options: .regularExpression
        )
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableDiagnosticsRawOutput") private var enableDiagnosticsRawOutput = false
    @State private var copied = false
    @State private var rawOutput: String?
    @State private var historyRecordCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                cliSection
                pollSection
                snapshotSection
                historySection
                warningsSection
                rawOutputSection
            }
            .formStyle(.grouped)
            .onAppear {
                rawOutput = try? SnapshotStore(directory: appState.storeDirectory).readRawOutput()
                loadHistoryMetadata()
            }

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

    private var cliSection: some View {
        Section("CLI") {
            LabeledContent("Path", value: effectiveCLIPath)
            LabeledContent("Status", value: cliStatus)
            if let snap = appState.snapshot {
                if let version = snap.source.cliVersion {
                    LabeledContent("Version", value: version)
                }
                LabeledContent("Last command", value: snap.source.command)
            }
        }
    }

    private var pollSection: some View {
        Section("Last Poll") {
            LabeledContent("Time", value: lastPollTimeText)
            if let err = appState.lastError {
                LabeledContent("Error") {
                    Text(DiagnosticsSanitizer.sanitize(err))
                        .foregroundStyle(Color.cmCritical)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                LabeledContent("Error", value: "None")
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

    private var historySection: some View {
        Section("History") {
            if appState.historyStore != nil {
                LabeledContent("Records", value: historyRecordCount.map { "\($0)" } ?? "…")
                LabeledContent("Store", value: appState.storeDirectory.path)
            } else {
                LabeledContent("Status", value: "Unavailable")
            }
        }
    }

    @ViewBuilder
    private var rawOutputSection: some View {
        if enableDiagnosticsRawOutput {
            Section("Raw CLI Output") {
                if let raw = rawOutput {
                    ScrollView {
                        Text(DiagnosticsSanitizer.sanitize(raw))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                } else {
                    Text("No raw output on disk — run a poll first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    private var effectiveCLIPath: String {
        let stored = (UserDefaults.standard.string(forKey: "claudeCliPath") ?? "")
            .trimmingCharacters(in: .whitespaces)
        if stored.isEmpty {
            return CLIPathDetector.detect() ?? "Not found"
        }
        return stored
    }

    private var cliStatus: String {
        let path = effectiveCLIPath
        guard path != "Not found" else { return "Not found" }
        return CLIPathDetector.verify(path: path) ? "Executable ✓" : "Not executable ✗"
    }

    private var lastPollTimeText: String {
        guard let date = appState.lastPolledAt else { return "Never" }
        return isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var isoFormatter: ISO8601DateFormatter { Self.isoFormatter }

    private func loadHistoryMetadata() {
        Task {
            historyRecordCount = try? await appState.historyStore?.recordCountAsync()
        }
    }

    // MARK: - Copy text

    private var diagnosticsText: String {
        var lines: [String] = [
            "=== Claude Meter Diagnostics (sanitized) ===",
            "Generated: \(isoFormatter.string(from: Date()))",
            "",
            "CLI",
            "  Path: \(effectiveCLIPath)",
            "  Status: \(cliStatus)",
            "",
            "Last Poll",
            "  Time: \(lastPollTimeText)",
            "  Error: \(DiagnosticsSanitizer.sanitize(appState.lastError ?? "None"))",
            "",
        ]

        if let snap = appState.snapshot {
            lines += [
                "Snapshot",
                "  Schema version: \(snap.schemaVersion)",
                "  Parser version: \(snap.parserVersion)",
                "  Created: \(isoFormatter.string(from: snap.createdAt))",
            ]
            if let version = snap.source.cliVersion {
                lines.append("  CLI version: \(version)")
            }
            lines.append("  Last command: \(snap.source.command)")
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
