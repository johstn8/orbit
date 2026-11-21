import Foundation
import AppKit

/// URL pattern matching shared with the extension (extension/src/shared/routing.ts).
/// Both implementations are tested against tests/fixtures/routing-cases.json.
enum RoutePattern {
    /// Does `pattern` match `url`?
    /// - `example.com` matches example.com and its subdomains
    /// - `*.example.com` same, written explicitly; `*` also works inside host names
    /// - `example.com/path` additionally requires the path to start with /path (`*` = any characters)
    /// - `/regex/` is matched against the whole URL, case-insensitively
    static func matches(_ pattern: String, _ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return false }
        var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        if p.count > 2 && p.hasPrefix("/") && p.hasSuffix("/") {
            let body = String(p.dropFirst().dropLast())
            guard let re = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]) else { return false }
            let s = url.absoluteString
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        for prefix in ["https://", "http://"] where p.lowercased().hasPrefix(prefix) { p = String(p.dropFirst(prefix.count)) }
        var hostPat = p
        var pathPat = ""
        if let slash = p.firstIndex(of: "/") {
            hostPat = String(p[..<slash])
            pathPat = String(p[slash...])
        }
        hostPat = hostPat.lowercased()
        if let colon = hostPat.firstIndex(of: ":") { hostPat = String(hostPat[..<colon]) }
        guard hostMatches(hostPat, host) else { return false }
        if pathPat.isEmpty || pathPat == "/" || pathPat == "/*" { return true }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        return glob(pathPat.hasSuffix("*") ? pathPat : pathPat + "*", path, caseInsensitive: false)
    }

    static func hostMatches(_ pat: String, _ host: String) -> Bool {
        if pat.hasPrefix("*.") {
            let base = String(pat.dropFirst(2))
            if !base.contains("*") { return host == base || host.hasSuffix("." + base) }
        }
        if pat.contains("*") { return glob(pat, host, caseInsensitive: true) }
        return host == pat || host.hasSuffix("." + pat)
    }

    static func glob(_ pattern: String, _ s: String, caseInsensitive: Bool) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        guard let re = try? NSRegularExpression(pattern: "^" + escaped + "$", options: caseInsensitive ? [.caseInsensitive] : []) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// First enabled rule that matches. A rule with an empty profile is an exception (no routing).
    static func target(for url: URL, rules: [RoutingRule]) -> String? {
        for r in rules where r.enabled && matches(r.pattern, url) {
            return r.profileId.isEmpty ? nil : r.profileId
        }
        return nil
    }
}

/// Routes URLs to Safari profiles: links from other apps (when Orbit is the
/// default browser) and navigations inside Safari that the extension intercepts.
final class Router {
    static let shared = Router()

    /// Recently routed URLs, to stop loops (A → B → A …).
    /// Used from the hub queue and the main thread.
    private var recent: [(url: String, to: String, at: Date, from: String?)] = []
    private let recentLock = NSLock()

    // MARK: requests from extension instances (hub queue)

    func handle(_ method: String, _ p: JSONObject, profile: String?, reply: @escaping Hub.Reply) {
        switch method {
        case "route.open":
            guard let raw = p["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let target = p["profileId"] as? String else { return reply(.failure(AgentError("bad_request", "Invalid route."))) }
            let now = Date()
            let s = SettingsStore.shared.current
            // Two ids of the same Safari profile (an old entry and the current one).
            let same = { (a: String, b: String) -> Bool in
                guard a != b else { return true }
                guard let x = s.profile(a), let y = s.profile(b) else { return false }
                return (x.detectedName ?? x.name) == (y.detectedName ?? y.name)
            }
            // Loop guards:
            // - the same URL was just routed *to* the profile that now wants to route it away;
            // - the target is the asking profile itself under another id (same Safari profile);
            // - another profile asks to send a URL to where it was just sent (the new tab there
            //   asks again, e.g. because that window's instance doesn't know yet which profile it is).
            recentLock.lock()
            recent.removeAll { now.timeIntervalSince($0.at) > 15 }
            let toAsker = profile.map { p in recent.contains { $0.url == raw && same($0.to, p) } } ?? false
            let sameProfile = profile.map { same($0, target) } ?? false
            let repeated = recent.contains { $0.url == raw && $0.to == target && $0.from != profile && now.timeIntervalSince($0.at) < 6 }
            if !(toAsker || sameProfile || repeated) { recent.append((raw, target, now, profile)) }
            recentLock.unlock()
            if toAsker || sameProfile || repeated {
                Log.routing.notice("route loop prevented")
                return reply(.success(["ok": false, "loop": true]))
            }
            Task {
                let outcome = await SafariController.open(url, profileId: target, newWindow: p["newWindow"] as? Bool ?? false, openAnywayOnFailure: false)
                switch outcome {
                case .done: reply(.success(["ok": true]))
                case .fallback(let notice):
                    // Safari shows the reason in the page; a permission problem also gets
                    // Orbit's notice, whose button opens the right settings pane.
                    if notice.isPermission { await MainActor.run { AppDelegate.shared?.notify(notice) } }
                    reply(.success(["ok": false, "reason": notice.reason]))
                }
            }
        case "route.pause":
            let minutes = p["minutes"] as? Double ?? 15
            SettingsStore.shared.update { $0.routing.pausedUntil = minutes <= 0 ? 0 : Date().timeIntervalSince1970 + minutes * 60 }
            reply(.success(["pausedUntil": SettingsStore.shared.current.routing.pausedUntil]))
        case "route.add_rule":
            guard let pattern = p["pattern"] as? String, !pattern.isEmpty, let target = p["profileId"] as? String else { return reply(.failure(AgentError("bad_request", "Missing rule."))) }
            SettingsStore.shared.update { s in
                s.routing.rules.removeAll { $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame }
                s.routing.rules.insert(RoutingRule(pattern: pattern, profileId: target), at: 0)
            }
            reply(.success(["ok": true]))
        case "route.remove_rule":
            guard let pattern = p["pattern"] as? String else { return reply(.failure(AgentError("bad_request", "Missing pattern."))) }
            SettingsStore.shared.update { s in s.routing.rules.removeAll { $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame } }
            reply(.success(["ok": true]))
        default:
            reply(.failure(AgentError("unknown_method", "Unknown method \(method).")))
        }
    }

    // MARK: links from other apps (main thread)

    @MainActor
    func handleExternal(_ url: URL) {
        let s = SettingsStore.shared.current
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            SafariController.openPlain(url)
            return
        }
        let profiles = s.pickerProfiles
        if profiles.count <= 1 {
            if let only = profiles.first { open(url, in: only.id) } else { SafariController.openPlain(url) }
            return
        }
        // Holding Option while clicking a link always shows the picker.
        let forcePicker = NSEvent.modifierFlags.contains(.option)
        if !forcePicker, s.routingActive, s.routing.externalLinks != "picker", let target = RoutePattern.target(for: url, rules: s.routing.rules), s.profile(target) != nil {
            open(url, in: target)
            return
        }
        if !forcePicker, s.routing.externalLinks == "last", let last = s.lastPickedProfile, s.profile(last) != nil {
            open(url, in: last)
            return
        }
        PickerController.shared.show(url: url) { [weak self] chosen in
            guard let chosen else { return }
            SettingsStore.shared.update { $0.lastPickedProfile = chosen }
            self?.open(url, in: chosen)
        }
    }

    @MainActor
    func open(_ url: URL, in profileId: String) {
        recentLock.withLock { recent.append((url.absoluteString, profileId, Date(), nil)) }
        Task {
            if case .fallback(let notice) = await SafariController.open(url, profileId: profileId) {
                await MainActor.run { AppDelegate.shared?.notify(notice) }
            }
        }
    }
}
