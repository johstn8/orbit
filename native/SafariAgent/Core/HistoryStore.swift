import Foundation

/// Orbit's shared history: the pages you visit in every Safari profile, kept locally
/// so you can search all profiles at once (Safari keeps history per profile and gives
/// extensions no history API). Recorded by each profile's Orbit extension; private
/// windows are never recorded. Stored in Application Support (0600), never sent
/// anywhere and not available to the AI agent.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct Visit: Codable, Identifiable, Hashable {
        var id: String { url }
        var url: String
        var title: String
        var profileId: String
        var lastVisit: Double     // seconds since 1970
        var count: Int
    }

    @Published private(set) var count = 0
    private var visits: [String: Visit] = [:]   // by URL (without fragment)
    private let queue = DispatchQueue(label: "dev.local.SafariAgent.history")
    private var saveScheduled = false
    static let maxEntries = 20_000

    private var file: URL { Paths.support.appendingPathComponent("history.json") }

    private init() {
        queue.async {
            if let d = try? Data(contentsOf: self.file), let list = try? JSONDecoder().decode([Visit].self, from: d) {
                for v in list { self.visits[v.url] = v }
            }
            self.prune()
            let n = self.visits.count
            DispatchQueue.main.async { self.count = n }
        }
    }

    static func key(_ url: String) -> String { url.components(separatedBy: "#").first ?? url }

    func add(profileId: String, url: String, title: String) {
        let s = SettingsStore.shared.current.history
        guard s.enabled, let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return }
        if s.excludedProfiles.contains(profileId) { return }
        let k = Self.key(url)
        queue.async {
            let now = Date().timeIntervalSince1970
            if var v = self.visits[k] {
                // A reload within a minute isn't a new visit.
                if now - v.lastVisit > 60 { v.count += 1 }
                v.lastVisit = now
                v.profileId = profileId
                if !title.isEmpty { v.title = String(title.prefix(300)) }
                self.visits[k] = v
            } else {
                self.visits[k] = Visit(url: k, title: String(title.prefix(300)), profileId: profileId, lastVisit: now, count: 1)
            }
            self.scheduleSave()
        }
    }

    /// Forget every page of a host (e.g. local test pages).
    func forget(host: String) {
        queue.async {
            self.visits = self.visits.filter { URL(string: $0.key)?.host?.lowercased() != host.lowercased() }
            self.scheduleSave()
        }
    }

    func clear() {
        queue.async {
            self.visits.removeAll()
            try? FileManager.default.removeItem(at: self.file)
            DispatchQueue.main.async { self.count = 0 }
        }
    }

    /// Search all profiles. Every word must appear in the title or URL; results are ranked
    /// by match quality, how often and how recently a page was visited.
    func search(_ query: String, limit: Int = 60) -> [Visit] {
        queue.sync {
            let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
            let now = Date().timeIntervalSince1970
            func score(_ v: Visit) -> Double? {
                let title = v.title.lowercased(), url = v.url.lowercased()
                var s = 0.0
                for w in words {
                    if title.contains(w) { s += title.hasPrefix(w) ? 3 : 2 }
                    else if url.contains(w) { s += (URL(string: v.url)?.host?.lowercased().contains(w) == true) ? 2.5 : 1 }
                    else { return nil }
                }
                let ageDays = max(0, (now - v.lastVisit) / 86400)
                return s + log2(Double(v.count) + 1) + 4 / (1 + ageDays)
            }
            let all = Array(visits.values)
            if words.isEmpty { return Array(all.sorted { $0.lastVisit > $1.lastVisit }.prefix(limit)) }
            return all.compactMap { v in score(v).map { (v, $0) } }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        }
    }

    private func prune() {
        let days = Double(SettingsStore.shared.current.history.retentionDays)
        let cutoff = Date().timeIntervalSince1970 - days * 86400
        visits = visits.filter { $0.value.lastVisit >= cutoff }
        if visits.count > Self.maxEntries {
            let keep = visits.values.sorted { $0.lastVisit > $1.lastVisit }.prefix(Self.maxEntries)
            visits = Dictionary(uniqueKeysWithValues: keep.map { ($0.url, $0) })
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 5) {
            self.saveScheduled = false
            self.prune()
            let list = Array(self.visits.values)
            try? Paths.writePrivate((try? JSONEncoder().encode(list)) ?? Data(), to: self.file)
            DispatchQueue.main.async { self.count = list.count }
        }
    }
}
