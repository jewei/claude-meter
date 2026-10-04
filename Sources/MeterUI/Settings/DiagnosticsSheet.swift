import AppKit
import MeterApp
import MeterDomain
import SwiftUI

/// The Diagnostics sheet: the redacted report, a Copy button, and Close (Escape).
struct DiagnosticsSheet: View {
    let load: @MainActor () async -> DiagnosticsReport

    @State private var report: DiagnosticsReport?
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rendersStatically) private var rendersStatically

    init(report: DiagnosticsReport? = nil, load: @escaping @MainActor () async -> DiagnosticsReport)
    {
        self.load = load
        _report = State(initialValue: report)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Diagnostics")
                    .font(MeterFont.display(26, .bold))
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Connection details to help you find a problem.")
                    .font(MeterFont.body(13, .semibold))
                    .foregroundStyle(Palette.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
            content.frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(Palette.popoverBorder).frame(height: 1)
            footer
        }
        .frame(width: 560, height: 520)
        .background(Palette.popover)
        .task {
            guard report == nil else { return }
            report = await load()
        }
        .task(id: copied) {
            // "Copied" shows for two seconds.
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    @ViewBuilder private var content: some View {
        if let report {
            let sections = VStack(alignment: .leading, spacing: 14) {
                ForEach(report.sections) { section in
                    DiagnosticsSectionView(section: section)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            if rendersStatically {
                sections
            } else {
                ScrollView { sections }
            }
        } else {
            Spinner().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                guard let report else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.text, forType: .string)
                copied = true
            } label: {
                ChunkyButtonLabel(title: "Copy Diagnostics", symbol: "doc.on.doc")
            }
            .buttonStyle(QuietButtonStyle(radius: 12))
            .disabled(report == nil)
            if copied {
                Text("Copied")
                    .font(MeterFont.body(12, .bold))
                    .foregroundStyle(Palette.heroFull.ink)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                ChunkyButtonLabel(title: "Close")
            }
            .buttonStyle(QuietButtonStyle(radius: 12))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
