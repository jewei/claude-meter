import ClaudeMeterCore
import Foundation

/// Fetches per-model Anthropic pricing from models.dev and caches it on disk for
/// 24 h, so cost estimates track current list prices instead of a hardcoded table
/// (our static `opus` rate, for instance, is the old Opus 3/4 price — Opus 4.5 is
/// ~3× cheaper). Falls back to the static `ModelPricing.current` family rates when
/// offline or when the fetched catalog looks implausible. Network + disk only —
/// never invoked from the sandboxed widget.
public enum ModelsDevPricing {
    static let apiURL = URL(string: "https://models.dev/api.json")!
    static let cacheTTL: TimeInterval = 24 * 60 * 60
    static let cacheFileName = "models-dev-pricing-v1.json"

    // Process-wide in-memory memo so repeated scans in one session don't re-read disk.
    private static let lock = NSLock()
    private static nonisolated(unsafe) var memo: CachedCatalog?

    /// Disk + memo cache payload.
    struct CachedCatalog: Codable, Sendable {
        let fetchedAt: Date
        let rates: [String: ModelPricing.Rate]
    }

    /// Per-model-id rate catalog (normalized lowercased ids), or `nil` when neither
    /// the network nor a usable disk cache yields a plausible catalog (caller then
    /// uses the static family rates).
    public static func loadCatalog(now: Date = Date()) async -> [String: ModelPricing.Rate]? {
        if let memo = freshMemo(now: now) { return memo.rates }
        if let disk = readDisk(), now.timeIntervalSince(disk.fetchedAt) < cacheTTL {
            setMemo(disk)
            return disk.rates
        }
        // Stale or absent → try the network, merging over any stale disk so a model
        // that vanished upstream keeps its last known price.
        if let fetched = await fetch() {
            let merged = merge(new: fetched, old: readDisk()?.rates)
            let cached = CachedCatalog(fetchedAt: now, rates: merged)
            writeDisk(cached)
            setMemo(cached)
            return merged
        }
        // Network failed — serve a stale disk cache if we have one.
        if let stale = readDisk() {
            setMemo(stale)
            return stale.rates
        }
        return nil
    }

    // MARK: - Memo

    private static func freshMemo(now: Date) -> CachedCatalog? {
        lock.lock()
        defer { lock.unlock() }
        guard let memo, now.timeIntervalSince(memo.fetchedAt) < cacheTTL else { return nil }
        return memo
    }

    private static func setMemo(_ value: CachedCatalog) {
        lock.lock()
        memo = value
        lock.unlock()
    }

    static func resetMemoForTesting() {
        lock.lock()
        memo = nil
        lock.unlock()
    }

    // MARK: - Network

    private static func fetch() async -> [String: ModelPricing.Rate]? {
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard
            let (data, http) = try? await ProviderHTTPClient.shared.send(request, retry: .transient),
            http.statusCode == 200
        else { return nil }
        return parseCatalog(from: data)
    }

    /// Parses the models.dev payload into an Anthropic rate catalog, returning `nil`
    /// unless the result is plausible. Exposed for tests (no network).
    static func parseCatalog(from data: Data) -> [String: ModelPricing.Rate]? {
        guard let resp = try? JSONDecoder().decode(APIResponse.self, from: data),
            let models = resp.anthropic?.models
        else { return nil }
        var rates: [String: ModelPricing.Rate] = [:]
        for (id, model) in models {
            guard let cost = model.cost, let input = cost.input, let output = cost.output,
                input > 0, output > 0
            else { continue }
            rates[id.lowercased()] = ModelPricing.Rate(
                input: input,
                output: output,
                cacheRead: cost.cacheRead ?? 0,
                cacheWrite: cost.cacheWrite ?? 0
            )
        }
        return isPlausible(rates) ? rates : nil
    }

    /// Guards against a malformed/partial upstream response replacing good prices.
    static func isPlausible(_ rates: [String: ModelPricing.Rate]) -> Bool {
        guard rates.count >= 5 else { return false }
        let hasOpus = rates.keys.contains { $0.contains("opus") }
        let hasSonnet = rates.keys.contains { $0.contains("sonnet") }
        return hasOpus && hasSonnet
    }

    /// New prices win; ids only present in the old cache are retained.
    static func merge(new: [String: ModelPricing.Rate], old: [String: ModelPricing.Rate]?)
        -> [String: ModelPricing.Rate]
    {
        guard let old else { return new }
        return old.merging(new) { _, fresh in fresh }
    }

    // MARK: - Disk

    static func cacheURL() -> URL? {
        guard
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let appDir = dir.appendingPathComponent("com.jewei.claudemeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent(cacheFileName)
    }

    private static func readDisk() -> CachedCatalog? {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachedCatalog.self, from: data)
    }

    private static func writeDisk(_ value: CachedCatalog) {
        guard let url = cacheURL(), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - models.dev JSON shapes (only what pricing needs)

    private struct APIResponse: Decodable {
        let anthropic: Provider?
    }

    private struct Provider: Decodable {
        let models: [String: Model]
    }

    private struct Model: Decodable {
        let cost: Cost?
    }

    private struct Cost: Decodable {
        let input: Double?
        let output: Double?
        let cacheRead: Double?
        let cacheWrite: Double?

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }
}
