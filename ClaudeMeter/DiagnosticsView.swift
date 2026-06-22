import SwiftUI
import ClaudeMeterCore

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                cliSection
                pollSection
                snapshotSection
                warningsSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Copy Diagnostics") {
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
        }
    }

    private var pollSection: some View {
        Section("Last Poll") {
            LabeledContent("Time", value: lastPollTimeText)
            if let err = appState.lastError {
                LabeledContent("Error") {
                    Text(err)
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

    @ViewBuilder
    private var warningsSection: some View {
        if let warnings = appState.lastPollResult?.warnings, !warnings.isEmpty {
            Section("Parser Warnings (\(warnings.count))") {
                ForEach(warnings, id: \.field) { w in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.field).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(w.message).font(.system(.caption, design: .monospaced))
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

    // MARK: - Copy text

    private var diagnosticsText: String {
        var lines: [String] = [
            "=== Claude Meter Diagnostics ===",
            "Generated: \(isoFormatter.string(from: Date()))",
            "",
            "CLI",
            "  Path: \(effectiveCLIPath)",
            "  Status: \(cliStatus)",
            "",
            "Last Poll",
            "  Time: \(lastPollTimeText)",
            "  Error: \(appState.lastError ?? "None")",
            "",
        ]

        if let snap = appState.snapshot {
            lines += [
                "Snapshot",
                "  Schema version: \(snap.schemaVersion)",
                "  Parser version: \(snap.parserVersion)",
                "  Created: \(isoFormatter.string(from: snap.createdAt))",
                "",
            ]
        }

        if let warnings = appState.lastPollResult?.warnings, !warnings.isEmpty {
            lines.append("Parser Warnings")
            for w in warnings {
                lines.append("  [\(w.field)] \(w.message)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
