import Foundation

/// Opt-in sharing of website logins between Safari profiles.
///
/// Safari keeps each profile's cookies separate and offers no API to share a
/// login. With the user's opt-in per website, Orbit copies that site's
/// cookies from the profile the user signs in with (source) into chosen target
/// profiles, through the Orbit extension instance in each profile
/// (browser.cookies). Cookies only pass through memory on this Mac: they are
/// never written to disk by Orbit, never logged and never available to the
/// AI tools. Other websites are never touched.
final class SessionSharing {
    static let shared = SessionSharing()

    private var pending: [String: DispatchWorkItem] = [:]   // site id → scheduled sync
    private var hub: Hub { Hub.shared }

    func domains(_ site: SharedSite) -> [String] {
        ([site.domain] + site.extraDomains).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    func targets(_ site: SharedSite, settings: AppSettings) -> [String] {
        let all = settings.listedProfiles.map(\.id).filter { $0 != site.sourceProfileId }
        return site.targets.isEmpty ? all : site.targets.filter { $0 != site.sourceProfileId && all.contains($0) }
    }

    /// Target profiles (names) that another enabled entry for the same website also writes to.
    static func conflicts(for site: SharedSite, in settings: AppSettings) -> [String] {
        guard site.enabled else { return [] }
        let me = shared.targets(site, settings: settings)
        let doms = Set(shared.domains(site))
        var hit = Set<String>()
        for other in settings.sharing where other.id != site.id && other.enabled && !doms.isDisjoint(with: shared.domains(other)) {
            for t in shared.targets(other, settings: settings) where me.contains(t) { hit.insert(t) }
            // Writing into the other entry's source would overwrite the login it shares.
            if me.contains(other.sourceProfileId) { hit.insert(other.sourceProfileId) }
        }
        return hit.compactMap { settings.profile($0)?.name }.sorted()
    }

    // MARK: triggers (hub queue)

    func settingsChanged(_ old: [SharedSite], _ new: [SharedSite]) {
        for site in new where site.enabled {
            let before = old.first { $0.id == site.id }
            if before == nil || before?.enabled == false || before?.sourceProfileId != site.sourceProfileId || before?.targets != site.targets {
                schedule(site.id, delay: 0.5)
            }
        }
    }

    /// The source profile reported changed cookies for a domain.
    func cookiesChanged(profile: String, domain: String) {
        let s = SettingsStore.shared.current
        for site in s.sharing where site.enabled && site.sourceProfileId == profile && domains(site).contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) {
            schedule(site.id, delay: 3)
        }
    }

    /// A profile connected: bring its shared logins up to date.
    func instanceConnected(_ profile: String) {
        let s = SettingsStore.shared.current
        for site in s.sharing where site.enabled && (site.sourceProfileId == profile || targets(site, settings: s).contains(profile)) {
            schedule(site.id, delay: 2)
        }
    }

    /// You're using a window of this profile: Safari now tells its cookie store, so bring
    /// logins it receives up to date (at most every 10 minutes per site, unless the last try failed).
    func profileActive(_ profile: String) {
        let s = SettingsStore.shared.current
        let now = Date().timeIntervalSince1970
        for site in s.sharing where site.enabled && targets(site, settings: s).contains(profile) {
            let ok = (site.lastResult ?? "").hasPrefix("Shared with") && !(site.lastResult ?? "").contains("will update")
            if !ok || now - (site.lastSync ?? 0) > 600 { schedule(site.id, delay: 1.5) }
        }
    }

    private func schedule(_ siteId: String, delay: Double) {
        pending[siteId]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sync(siteId, completion: nil) }
        pending[siteId] = w
        hub.queue.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: requests

    func handle(_ method: String, _ p: JSONObject, profile: String?, reply: @escaping Hub.Reply) {
        switch method {
        case "sessions.sync":
            guard let id = p["siteId"] as? String else { return reply(.failure(AgentError("bad_request", "Missing site."))) }
            sync(id) { result in reply(.success(["result": result])) }
        default:
            reply(.failure(AgentError("unknown_method", "Unknown method \(method).")))
        }
    }

    // MARK: sync

    /// The source profile's last exported login per site, kept in memory only (never on
    /// disk), so target profiles can be updated while the source profile's extension sleeps.
    private var cache: [String: (cookies: [JSONObject], at: Date, source: String)] = [:]
    private static let cacheLifetime: TimeInterval = 12 * 3600

    func sync(_ siteId: String, completion: ((String) -> Void)?) {
        let s = SettingsStore.shared.current
        guard let site = s.sharing.first(where: { $0.id == siteId }), site.enabled, !site.domain.isEmpty else { completion?("Sharing is off."); return }
        let doms = domains(site)
        let sourceName = s.profile(site.sourceProfileId)?.name ?? "the source profile"
        let fromCache = { [weak self] () -> Bool in
            guard let self, let c = self.cache[site.id], c.source == site.sourceProfileId, Date().timeIntervalSince(c.at) < Self.cacheLifetime else { return false }
            self.distribute(site, c.cookies, settings: s, completion: completion)
            return true
        }
        guard hub.instances[site.sourceProfileId] != nil else {
            if fromCache() { return }
            let had = targets(site, settings: s).filter { site.syncedTargets[$0] != nil }.compactMap { s.profile($0)?.name }.sorted()
            finish(site, had.isEmpty ? "Waiting for \(sourceName) to be in use in Safari." : "Shared with \(had.joined(separator: ", ")). New changes follow when \(sourceName) is in use.", completion)
            return
        }
        hub.callInstance(site.sourceProfileId, "cookies_export", ["domains": doms], timeout: 10) { [weak self] r in
            guard let self else { return }
            guard case .success(let v) = r, let o = v as? JSONObject, let cookies = o["cookies"] as? [JSONObject] else {
                if fromCache() { return }
                if case .failure(let e) = r { self.finish(site, "Couldn't read the login in \(sourceName): \(e.message)", completion) }
                else { self.finish(site, "Couldn't read the login.", completion) }
                return
            }
            let excluded = Set(site.excludedCookies.map { $0.lowercased() })
            let filtered = cookies.filter { !excluded.contains(($0["name"] as? String ?? "").lowercased()) }
            if filtered.isEmpty {
                self.finish(site, "No login found in \(sourceName). Sign in there first.", completion)
                return
            }
            self.cache[site.id] = (filtered, Date(), site.sourceProfileId)
            self.distribute(site, filtered, settings: s, completion: completion)
        }
    }

    private func distribute(_ site: SharedSite, _ filtered: [JSONObject], settings s: AppSettings, completion: ((String) -> Void)?) {
        let doms = domains(site)
        let excluded = Set(site.excludedCookies.map { $0.lowercased() })
        let targetIds = targets(site, settings: s)
        let group = DispatchGroup()
        var done: [String] = []
        var doneIds: [String] = []
        var waiting: [String] = []
        var problems: [String] = []
        for t in targetIds {
            let name = s.profile(t)?.name ?? "Profile"
            guard hub.instances[t] != nil else {
                // Asleep now, but it already has this login from an earlier sync.
                if site.syncedTargets[t] != nil { done.append(name) } else { waiting.append(name) }
                continue
            }
            group.enter()
            hub.callInstance(t, "cookies_import", ["domains": doms, "cookies": filtered, "excluded": Array(excluded)], timeout: 20) { r in
                switch r {
                case .success(let v):
                    // Count it only when the target's store really holds the source's values now.
                    let o = v as? JSONObject ?? [:]
                    let verified = o["verified"] as? Int ?? 0, expected = o["expected"] as? Int ?? 0
                    let missing = o["missing"] as? [String] ?? []
                    // A login is shared when everything arrived, or only minor cookies (not
                    // session/auth ones) were refused by Safari.
                    let critical = missing.filter { n in ["session", "auth", "token", "sid", "login", "user"].contains { n.lowercased().contains($0) } }
                    if expected == 0 || verified >= expected { done.append(name); doneIds.append(t) }
                    else if critical.isEmpty && verified * 10 >= expected * 9 { done.append(name); doneIds.append(t) }
                    else { problems.append("\(name): \(verified) of \(expected) cookies arrived (missing \(missing.prefix(3).joined(separator: ", ")))") }
                case .failure(let e):
                    if e.message.contains("no open tab") {
                        if site.syncedTargets[t] != nil { done.append(name) } else { waiting.append(name) }
                    } else { problems.append("\(name): \(e.message)") }
                }
                group.leave()
            }
        }
        group.notify(queue: hub.queue) {
            var parts: [String] = []
            if !done.isEmpty { parts.append("Shared with \(done.sorted().joined(separator: ", ")).") }
            if !problems.isEmpty { parts.append("Problem — \(problems.sorted().joined(separator: "; ")).") }
            if !waiting.isEmpty { parts.append("\(waiting.sorted().joined(separator: ", ")) will update when \(waiting.count == 1 ? "it's" : "they're") in use in Safari.") }
            self.finish(site, parts.isEmpty ? "No target profiles." : parts.joined(separator: " "), syncedNow: doneIds, completion)
        }
    }

    private func finish(_ site: SharedSite, _ result: String, syncedNow: [String] = [], _ completion: ((String) -> Void)?) {
        SettingsStore.shared.update { s in
            if let i = s.sharing.firstIndex(where: { $0.id == site.id }) {
                for t in syncedNow { s.sharing[i].syncedTargets[t] = Date().timeIntervalSince1970 }
                s.sharing[i].lastSync = Date().timeIntervalSince1970
                s.sharing[i].lastResult = result
            }
        }
        completion?(result)
    }
}
