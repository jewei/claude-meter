/// An O(1) least-recently-used order for dictionary-backed caches.
///
/// Values stay in each cache's own dictionary. This type owns only the linked
/// key order, so touching or evicting an entry does not copy a cached payload.
struct LRUKeyIndex<Key: Hashable> {
    private struct Links {
        var older: Key?
        var newer: Key?
    }

    private var links: [Key: Links] = [:]
    private var leastRecent: Key?
    private var mostRecent: Key?

    var count: Int { links.count }

    mutating func touch(_ key: Key) {
        if links[key] != nil { detach(key) }

        links[key] = Links(older: mostRecent, newer: nil)
        if let mostRecent {
            var prior = links[mostRecent]!
            prior.newer = key
            links[mostRecent] = prior
        } else {
            leastRecent = key
        }
        mostRecent = key
    }

    @discardableResult
    mutating func remove(_ key: Key) -> Bool {
        guard links[key] != nil else { return false }
        detach(key)
        return true
    }

    mutating func popLeastRecent() -> Key? {
        guard let key = leastRecent else { return nil }
        detach(key)
        return key
    }

    mutating func removeAll() {
        links.removeAll(keepingCapacity: false)
        leastRecent = nil
        mostRecent = nil
    }

    func keysFromLeastToMostRecent() -> [Key] {
        var result: [Key] = []
        result.reserveCapacity(links.count)
        var key = leastRecent
        while let current = key, result.count < links.count {
            result.append(current)
            key = links[current]?.newer
        }
        return result
    }

    private mutating func detach(_ key: Key) {
        guard let node = links.removeValue(forKey: key) else { return }

        if let older = node.older {
            var prior = links[older]!
            prior.newer = node.newer
            links[older] = prior
        } else {
            leastRecent = node.newer
        }

        if let newer = node.newer {
            var next = links[newer]!
            next.older = node.older
            links[newer] = next
        } else {
            mostRecent = node.older
        }
    }
}
