import MeterApp
import MeterDomain
import SwiftUI

/// The shared layout of a config-dir or Codex-home row: avatar, name field, details, and
/// trailing controls on a soft rounded surface.
///
/// A row that can be removed ends with a trash button that asks in the row first
/// (``InlineConfirmation``), because removal also forgets the settings of the account, which
/// the question lists for its provider. A login that is not tracked dims only its avatar; its
/// text keeps full contrast.
struct FolderRow<Details: View, Controls: View>: View {
    let id: String
    let provider: ProviderID
    let name: String?
    let defaultName: String
    var isTracked = true
    let rename: (String) -> Void
    /// Nil when the row cannot be removed.
    var remove: (() -> Void)?
    @ViewBuilder let details: Details
    @ViewBuilder let controls: Controls

    @State private var confirmsRemoval: Bool

    init(
        id: String, provider: ProviderID, name: String?, defaultName: String,
        isTracked: Bool = true,
        rename: @escaping (String) -> Void, remove: (() -> Void)? = nil,
        confirmsRemoval: Bool = false, @ViewBuilder details: () -> Details,
        @ViewBuilder controls: () -> Controls
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.defaultName = defaultName
        self.isTracked = isTracked
        self.rename = rename
        self.remove = remove
        self.details = details()
        self.controls = controls()
        _confirmsRemoval = State(initialValue: confirmsRemoval)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let shownName = name ?? defaultName
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AccountAvatar(id: id, name: shownName)
                    .opacity(isTracked ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 7) {
                    DisplayNameField(name: name, placeholder: defaultName, save: rename)
                    details
                }
                HStack(spacing: 6) {
                    controls
                    if remove != nil {
                        RemoveButton(name: shownName) { confirmsRemoval = true }
                            .disabled(confirmsRemoval)
                    }
                }
                .frame(minHeight: 30)
            }
            if confirmsRemoval, let remove {
                InlineConfirmation(
                    confirmation: DataSourceText.removeConfirmation(
                        name: shownName, provider: provider)
                ) {
                    confirmsRemoval = false
                    remove()
                } cancel: {
                    confirmsRemoval = false
                }
            }
        }
        .padding(10)
        .background(shape.fill(Palette.popover))
        .overlay(shape.strokeBorder(Palette.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shownName)
    }
}
