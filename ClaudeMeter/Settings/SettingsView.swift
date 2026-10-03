import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection = 0

    private static let tabs: [(icon: String, title: String)] = [
        ("cylinder.split.1x2", "Data"),
        ("paintpalette.fill", "Appearance"),
        ("slider.horizontal.3", "Advanced"),
        ("info.circle", "About"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().overlay(Color.pfPopoverBorder)
            Group {
                switch selection {
                case 0: DataSettingsTab(appState: appState)
                case 1: AppearanceSettingsTab()
                case 2: AdvancedSettingsTab(appState: appState)
                default: AboutSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 580, height: 700)
        .tint(Color.pfHeroFullInk)
        .background(Color.pfPopover)
        .background(SettingsWindowAccessor())
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(Array(Self.tabs.enumerated()), id: \.offset) { index, tab in
                tabButton(index, tab.icon, tab.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings tabs")
    }

    private func tabButton(_ index: Int, _ icon: String, _ title: String) -> some View {
        let selected = selection == index
        return Button {
            selection = index
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(title).font(PFont.body(12, .heavy))
            }
            .foregroundStyle(selected ? Color.pfHeroFullInk : Color.pfInkMuted)
            .frame(width: 112)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.pfHeroFullBG : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                selected ? Color.pfHeroFullBorder : Color.clear, lineWidth: 1.5)
                    }
            )
        }
        .buttonStyle(QuietButtonStyle(radius: 14))
        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(title) (⌘\(index + 1))")
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    /// Also read by `AppUpdater`, which must not drop an LSUIElement app to
    /// `.accessory` while this window is open (that strands it without Cmd-Tab).
    /// It can only find the window by title, so the string lives here once
    /// instead of being repeated at the match site.
    static let windowTitle = "Claude Meter — Settings"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
            view.window?.title = Self.windowTitle
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.title = Self.windowTitle }
    }
}

/// Whether the Settings window is currently on screen.
@MainActor
func isSettingsWindowVisible() -> Bool {
    NSApp.windows.contains { $0.isVisible && $0.title == SettingsWindowAccessor.windowTitle }
}

/// Shared hierarchy for the settings pages.
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(PFont.display(26, .bold))
                .foregroundStyle(Color.pfInk)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(PFont.body(13, .semibold))
                .foregroundStyle(Color.pfInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }
}
