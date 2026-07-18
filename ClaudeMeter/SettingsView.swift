import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection = 0

    private static let tabs: [(icon: String, title: String)] = [
        ("cylinder.split.1x2", "Data"),
        ("paintpalette.fill", "Appearance"),
        ("bell", "Notifications"),
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
                case 1: AppearanceSettingsTab(appState: appState)
                case 2: NotificationsSettingsTab(appState: appState)
                case 3: AdvancedSettingsTab(appState: appState)
                default: AboutSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 640)
        .background(Color.pfPopover)
        .background(SettingsWindowAccessor())
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(Array(Self.tabs.enumerated()), id: \.offset) { index, tab in
                tabButton(index, tab.icon, tab.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
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
            .frame(width: 96)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.pfHeroFullBG : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.level = .floating
            view.window?.title = "Claude Meter — Settings"
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.title = "Claude Meter — Settings" }
    }
}
