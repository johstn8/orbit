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

    func sync(_ siteId: String, completion: ((String) -> Void)?) {
        let s = SettingsStore.shared.current
        guard let site = s.sharing.first(where: { $0.id == siteId }), site.enabled else { completion?("Sharing is off."); return }
        let doms = domains(site)
        let targetIds = targets(site, settings: s)
        guard hub.instances[site.sourceProfileId] != nil else {
            finish(site, "Waiting for the \(s.profile(site.sourceProfileId)?.name ?? "source") profile to be open in Safari.", completion)
            return
        }
        hub.callInstance(site.sourceProfileId, "cookies_export", ["domains": doms], timeout: 10) { [weak self] r in
            guard let self else { return }
            guard case .success(let v) = r, let o = v as? JSONObject, let cookies = o["cookies"] as? [JSONObject] else {
                if case .failure(let e) = r { self.finish(site, "Couldn't read the login: \(e.message)", completion) }
                else { self.finish(site, "Couldn't read the login.", completion) }
                return
            }
            let excluded = Set(site.excludedCookies.map { $0.lowercased() })
            let filtered = cookies.filter { !excluded.contains(($0["name"] as? String ?? "").lowercased()) }
            if filtered.isEmpty {
                self.finish(site, "No login found in \(s.profile(site.sourceProfileId)?.name ?? "the source profile"). Sign in there first.", completion)
                return
            }
            let group = DispatchGroup()
            var done: [String] = []
            var waiting: [String] = []
            for t in targetIds {
                let name = s.profile(t)?.name ?? "Profile"
                guard self.hub.instances[t] != nil else { waiting.append(name); continue }
                group.enter()
                self.hub.callInstance(t, "cookies_import", ["domains": doms, "cookies": filtered, "excluded": Array(excluded)], timeout: 15) { r in
                    if case .success = r { done.append(name) } else { waiting.append(name) }
                    group.leave()
                }
            }
            group.notify(queue: self.hub.queue) {
                var msg = done.isEmpty ? "" : "Shared with \(done.sorted().joined(separator: ", "))."
                if !waiting.isEmpty { msg += (msg.isEmpty ? "" : " ") + "Will update \(waiting.sorted().joined(separator: ", ")) when open in Safari." }
                self.finish(site, msg.isEmpty ? "No target profiles." : msg, completion)
            }
        }
    }

    private func finish(_ site: SharedSite, _ result: String, _ completion: ((String) -> Void)?) {
        SettingsStore.shared.update { s in
            if let i = s.sharing.firstIndex(where: { $0.id == site.id }) {
                s.sharing[i].lastSync = Date().timeIntervalSince1970
                s.sharing[i].lastResult = result
            }
        }
        completion?(result)
    }
}
