import ClaudeMeterCore
import Foundation

/// Decodes the reset inventory in Claude's web Usage response.
public enum ClaudeWebResetPayload {
    /// Runs in the signed-in Claude web page. It returns only organization IDs and reset offers.
    public static let readScript = """
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 10000);
        try {
            const options = { credentials: 'include', signal: controller.signal };
            const reply = value => JSON.stringify(value);
            const orgResponse = await fetch('/api/organizations', options);
            if (orgResponse.status === 401 || orgResponse.status === 403) {
                return reply({ kind: 'signInRequired' });
            }
            if (!orgResponse.ok) return reply({ kind: 'requestFailed' });
            const organizations = await orgResponse.json();
            if (!Array.isArray(organizations)) return reply({ kind: 'invalidResponse' });
            const chatOrgs = organizations.filter(item =>
                typeof item.uuid === 'string'
                && /^[0-9a-f-]{36}$/i.test(item.uuid)).slice(0, 32);
            const records = [];
            for (const org of chatOrgs) {
                const path = '/api/organizations/' + encodeURIComponent(org.uuid)
                    + '/usage?cedar_ember=1&skip_spend=1';
                const usageResponse = await fetch(path, options);
                if (usageResponse.status === 401 || usageResponse.status === 403) {
                    return reply({ kind: 'signInRequired' });
                }
                if (!usageResponse.ok) continue;
                const usage = await usageResponse.json();
                if (usage !== null && typeof usage === 'object'
                    && usage.cedar_ember != null) {
                    records.push({
                        organizationID: org.uuid,
                        resetJSON: JSON.stringify({ cedar_ember: usage.cedar_ember })
                    });
                }
            }
            return reply({ kind: 'success', records });
        } catch (_) {
            return JSON.stringify({ kind: 'requestFailed' });
        } finally {
            clearTimeout(timer);
        }
        """

    public static func parse(_ data: Data) -> ClaudeLimitResets? {
        guard let payload = try? JSONDecoder().decode(UsagePayload.self, from: data),
            let reset = payload.cedarEmber,
            reset.eligible
        else { return nil }

        let offers = (reset.grants ?? []).prefix(32).compactMap { grant -> ClaudeLimitResetOffer? in
            guard (0...1000).contains(grant.resetsLeft), grant.paused != true else { return nil }
            let startsAt = parseEpochOrISODate(grant.startsAt)
            let expiresAt = parseEpochOrISODate(grant.endsAt)
            if grant.startsAt != nil && startsAt == nil { return nil }
            if grant.endsAt != nil && expiresAt == nil { return nil }
            let title = grant.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ClaudeLimitResetOffer(
                title: title.isEmpty ? "Usage reset" : String(title.prefix(120)),
                remainingCount: grant.resetsLeft,
                startsAt: startsAt,
                expiresAt: expiresAt)
        }
        return ClaudeLimitResets(offers: offers)
    }

    private struct UsagePayload: Decodable {
        let cedarEmber: ResetInventory?

        enum CodingKeys: String, CodingKey {
            case cedarEmber = "cedar_ember"
        }
    }

    private struct ResetInventory: Decodable {
        let eligible: Bool
        let grants: [Grant]?
    }

    private struct Grant: Decodable {
        let label: String?
        let resetsLeft: Int
        let startsAt: String?
        let endsAt: String?
        let paused: Bool?

        enum CodingKeys: String, CodingKey {
            case label, paused
            case resetsLeft = "resets_left"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
        }
    }
}
