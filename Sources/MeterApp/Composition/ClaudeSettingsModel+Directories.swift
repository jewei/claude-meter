import Foundation
import MeterDomain
import ProviderClaude

/// The config dirs of Settings > Data > Claude, and the names and plans of their accounts.
extension ClaudeSettingsModel {
    /// The config dirs, default first, then any login in the latest reading that matches no
    /// config dir, so the user can name it and set its plan. The switch state, the remove
    /// button, and the reported plan come from the current settings and reading each time, so
    /// they never lag behind.
    public var accounts: [Account] {
        let configuration = settings.claudeConfiguration
        let reported = usage.readings[.claude]?.value
        let directories = discovered.map { account in
            Account(
                id: account.id, defaultName: PresentationContext.friendlyName(account.name),
                path: account.directory.path, isDefault: account.isDefault,
                isEnabled: configuration.isEnabled(account.id),
                isRemovable: isConfigured(account),
                reportedPlan: reported?.account(account.id)?.plan,
                issue: account.issue?.message)
        }
        let listed = Set(discovered.map(\.id))
        let unmapped = (reported?.accounts ?? []).filter { !listed.contains($0.id) }.map { usage in
            Account(
                id: usage.id, defaultName: PresentationContext.friendlyName(usage.name),
                path: nil, isDefault: usage.id == ClaudeAccount.defaultID, isEnabled: true,
                isRemovable: false, reportedPlan: usage.plan, issue: nil)
        }
        return directories + unmapped
    }

    /// Adds a folder that holds `settings.json` or `projects`. Returns false and sets
    /// ``directoryMessage`` when the folder is not a Claude config dir (or does not answer
    /// within 5 s), when it or a folder with the same account key is already listed, including
    /// the default dir before the first reload, or when the config dirs cannot be listed now.
    @discardableResult
    public func addDirectory(_ url: URL) async -> Bool {
        guard let canonical = await ClaudeProvider.configDirectory(at: url) else {
            directoryMessage = "Choose a folder that holds settings.json or projects."
            return false
        }
        // A fresh discovery, so the default dir counts even before the first reload.
        guard let found = try? await provider.accounts(for: settings.claudeConfiguration) else {
            directoryMessage = "Could not list the config dirs. Try again."
            return false
        }
        let listed = found.map(\.canonicalPath) + settings.settings.claude.extraDirectories
        guard !listed.contains(canonical.path) else {
            directoryMessage = "That config dir is already listed."
            return false
        }
        // Accounts are keyed by folder name. A second folder with a listed key would be saved
        // but never listed, so the user could not remove it.
        guard !found.contains(where: { $0.id == ClaudeAccount.key(for: canonical) }) else {
            directoryMessage =
                "A config dir with this folder name is already listed. Rename the folder, then "
                + "add it."
            return false
        }
        directoryMessage = nil
        settings.update { $0.claude.extraDirectories.append(canonical.path) }
        return true
    }

    /// Removes a folder that the user added, with its name, plan badge, switch, and pin.
    public func removeDirectory(_ id: AccountID) {
        guard let account = discovered.first(where: { $0.id == id }), isConfigured(account) else {
            return
        }
        let paths: Set = [account.canonicalPath, account.directory.path]
        settings.update { settings in
            settings.claude.extraDirectories.removeAll { paths.contains($0) }
            settings.forgetAccount(id, of: .claude)
        }
    }

    /// The default account can never be turned off.
    public func setEnabled(_ id: AccountID, _ isEnabled: Bool) {
        guard id != ClaudeAccount.defaultID else { return }
        settings.update { settings in
            if isEnabled {
                settings.claude.disabledAccounts.remove(id)
            } else {
                settings.claude.disabledAccounts.insert(id)
            }
        }
    }

    /// Stores the trimmed name. A blank name removes it. An account that is not listed is
    /// ignored, so a name edit that ends after its folder was removed cannot bring it back.
    public func rename(_ id: AccountID, to name: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.claude.accountNames[id] = trimmed.isEmpty ? nil : trimmed }
    }

    /// A badge for a login that reports no plan. Nil or a blank plan removes it.
    public func setPlanOverride(_ id: AccountID, _ plan: String?) {
        let trimmed = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.update { $0.claude.planOverrides[id] = trimmed?.isEmpty == false ? trimmed : nil }
    }

    /// The user added this folder. Settings stores the canonical path from the time it was
    /// added, and the listed account can show the same folder under another path, such as a
    /// `~/.claude-*` link to it, so both forms are compared.
    private func isConfigured(_ account: ClaudeAccount) -> Bool {
        let configured = settings.settings.claude.extraDirectories
        return configured.contains(account.canonicalPath)
            || configured.contains(account.directory.path)
    }
}
