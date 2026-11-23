import Foundation

/// The plan usage limits each AI provider last reported (5-hour and weekly window),
/// shown as a ring in the sidebar. Nothing is fetched for this: Claude Code reports them
/// in its normal output (`rate_limit_event`) and ChatGPT in the headers of its normal
/// responses, so no extra request ever uses quota. Kept in Application Support (0600)
/// so the ring is there after a restart; it holds only percentages and reset times.
final class UsageStore {
    static let shared = UsageStore()

    struct Window: Codable, Equatable {
        var id: String          // "five_hour" | "weekly"
        var used: Double        // percent 0...100
        var resetsAt: Double?   // seconds since 1970
    }
    struct Usage: Codable, Equatable {
        var windows: [Window]
        var updatedAt: Double
    }

    private let queue = DispatchQueue(label: "dev.local.SafariAgent.usage")
    private var byProvider: [String: Usage] = [:]
    var onChange: (() -> Void)?

    private var file: URL { Paths.support.appendingPathComponent("usage.json") }

    private init() {
        if let d = try? Data(contentsOf: file), let v = try? JSONDecoder().decode([String: Usage].self, from: d) { byProvider = v }
    }

    /// Merge newly reported windows (a report may carry only one of them).
    func update(_ provider: String, _ windows: [Window]) {
        guard !windows.isEmpty else { return }
        var changed = false
        queue.sync {
            var u = byProvider[provider] ?? Usage(windows: [], updatedAt: 0)
            for w in windows {
                var w = w
                w.used = max(0, min(100, w.used))
                if let i = u.windows.firstIndex(where: { $0.id == w.id }) { if u.windows[i] != w { u.windows[i] = w; changed = true } }
                else { u.windows.append(w); changed = true }
            }
            u.windows.sort { Self.order($0.id) < Self.order($1.id) }
            u.updatedAt = Date().timeIntervalSince1970
            byProvider[provider] = u
            if changed, let d = try? JSONEncoder().encode(byProvider) {
                try? d.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        if changed { onChange?() }
    }

    static func order(_ id: String) -> Int { id == "five_hour" ? 0 : 1 }

    /// For the extension: windows whose reset time has passed count as 0 %.
    func json(now: Double = Date().timeIntervalSince1970) -> JSONObject {
        queue.sync {
            var out: JSONObject = [:]
            for (p, u) in byProvider {
                out[p] = ["updatedAt": u.updatedAt, "windows": u.windows.map { w -> JSONObject in
                    let expired = (w.resetsAt ?? .infinity) <= now
                    return ["id": w.id, "used": expired ? 0 : w.used, "resetsAt": expired ? NSNull() : (w.resetsAt as Any? ?? NSNull())]
                }]
            }
            return out
        }
    }

    // MARK: parsing (pure, unit-tested)

    /// Percent from a value that may be a fraction (Anthropic's utilization, 0...1) or
    /// already a percentage.
    static func percent(_ v: Double, fraction: Bool) -> Double { fraction ? v * 100 : v }

    /// `rate_limit_info` of Claude Code's `rate_limit_event`.
    static func fromClaude(_ info: JSONObject) -> [Window] {
        var out: [Window] = []
        let num = { (v: Any?) -> Double? in (v as? NSNumber)?.doubleValue }
        if let uw = info["unifiedWindows"] as? JSONObject {
            for (key, id) in [("five_hour", "five_hour"), ("seven_day", "weekly")] {
                if let w = uw[key] as? JSONObject, let u = num(w["utilization"]) {
                    out.append(Window(id: id, used: percent(u, fraction: true), resetsAt: num(w["resetsAt"])))
                }
            }
        }
        if out.isEmpty, let u = num(info["utilization"]), let t = info["rateLimitType"] as? String {
            let id = t == "five_hour" ? "five_hour" : t.hasPrefix("seven_day") ? "weekly" : nil
            if let id { out.append(Window(id: id, used: percent(u, fraction: true), resetsAt: num(info["resetsAt"]))) }
        }
        return out
    }

    /// Codex-style `rate_limits` object: primary/secondary with used_percent,
    /// window_minutes and resets_at (seconds since 1970).
    static func fromRateLimits(_ rl: JSONObject) -> [Window] {
        var out: [Window] = []
        for slot in ["primary", "secondary"] {
            guard let w = rl[slot] as? JSONObject, let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["window_minutes"] as? NSNumber)?.doubleValue
            let id = minutes.map { $0 <= 24 * 60 ? "five_hour" : "weekly" } ?? (slot == "primary" ? "five_hour" : "weekly")
            out.append(Window(id: id, used: used, resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue))
        }
        return out
    }

    /// ChatGPT/Codex rate-limit headers (`x-codex-primary-used-percent`, …window-minutes,
    /// …reset-at or …reset-after-seconds; the same for `secondary`). Keys lowercased.
    static func fromHeaders(_ h: [String: String], now: Double = Date().timeIntervalSince1970) -> [Window] {
        var out: [Window] = []
        for slot in ["primary", "secondary"] {
            let p = "x-codex-\(slot)-"
            guard let used = h[p + "used-percent"].flatMap(Double.init) else { continue }
            let minutes = h[p + "window-minutes"].flatMap(Double.init)
            let resets = h[p + "reset-at"].flatMap(Double.init) ?? h[p + "reset-after-seconds"].flatMap(Double.init).map { now + $0 }
            let id: String
            if let m = minutes { id = m <= 24 * 60 ? "five_hour" : "weekly" } else { id = slot == "primary" ? "five_hour" : "weekly" }
            out.append(Window(id: id, used: used, resetsAt: resets))
        }
        return out
    }
}
