import Foundation
import AppKit

/// A running assistant turn for one conversation.
final class Run {
    let conversationId: String
    let messageId: String
    let provider: String
    /// Safari profile whose extension instance owns this chat (where the user typed it).
    let profileId: String
    /// Browser access: "tab" | "window" | "all" (all authorized windows and profiles).
    var tabScope = "tab"
    /// Approval mode chosen in the panel: "sensitive" | "always" | "never".
    var approvalMode = "sensitive"
    var cancelled = false
    var finished = false
    var cancelHandler: (() -> Void)?
    var toolSeq = 0
    var pendingToolCalls: Set<String> = []

    init(conversationId: String, messageId: String, provider: String, profileId: String) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.provider = provider
        self.profileId = profileId
    }
}

/// Interface the providers use to report progress of a turn.
final class TurnSink {
    private weak var hub: Hub?
    let run: Run
    init(hub: Hub, run: Run) { self.hub = hub; self.run = run }

    var isCancelled: Bool { run.cancelled }
    func text(_ t: String) { hub?.queue.async { self.hub?.emit(self.run, ["kind": "text_delta", "messageId": self.run.messageId, "text": t]) } }
    func status(_ t: String) { hub?.queue.async { self.hub?.emit(self.run, ["kind": "status", "text": t]) } }
    func callTool(name: String, args: JSONObject, completion: @escaping (ToolOutcome) -> Void) {
        hub?.queue.async { self.hub?.executeTool(run: self.run, name: name, args: args, completion: completion) }
    }
    func finish(error: AgentError? = nil, cancelled: Bool = false) {
        hub?.queue.async { self.hub?.finishRun(self.run, error: error, cancelled: cancelled) }
    }
    func setClaudeSession(_ id: String) {
        hub?.queue.async { self.hub?.setClaudeSession(conversationId: self.run.conversationId, sessionId: id) }
    }
}

/// Result of a tool call.
struct ToolOutcome {
    var content: [JSONObject]   // [{type:"text",text} | {type:"image",data,mediaType}]
    var isError: Bool

    static func error(_ msg: String) -> ToolOutcome { ToolOutcome(content: [["type": "text", "text": msg]], isError: true) }
    static func ok(_ msg: String) -> ToolOutcome { ToolOutcome(content: [["type": "text", "text": msg]], isError: false) }
    var text: String { content.compactMap { $0["text"] as? String }.joined(separator: "\n") }
}

protocol Provider: AnyObject {
    var id: String { get }
    func status(refresh: Bool, completion: @escaping (JSONObject) -> Void)
    func startTurn(conversation: Conversation, userText: String, model: String?, effort: String?, sink: TurnSink)
    func forget(conversationId: String)
}

/// One connected Safari extension instance. Safari runs a separate instance of
/// the extension in every profile, each with its own tabs, windows and storage.
final class ExtensionInstance {
    let client: WSClient
    let profileId: String
    let version: String
    let connectedAt = Date()
    var lastActive = Date()
    /// Last time one of this profile's windows was focused (for "most recently used").
    var lastFocused: Date?

    init(client: WSClient, profileId: String, version: String) {
        self.client = client
        self.profileId = profileId
        self.version = version
    }
}

final class Hub {
    static let shared = Hub()
    let queue = DispatchQueue(label: "dev.local.SafariAgent.hub")
    let server: WebSocketServer
    let store = ConversationStore()
    private(set) var token = Random.token()
    private(set) var port: UInt16 = 0

    private var clients = Set<WSClient>()
    /// Connected extension instances by Safari profile id.
    private(set) var instances: [String: ExtensionInstance] = [:]
    /// Recent connect/disconnect events (diagnostics only; no page data).
    /// Written on the hub queue, read from the main thread (settings window), so every
    /// access goes through a lock: an unsynchronized read while the hub replaces the array
    /// corrupts its reference count and crashed Orbit (1.1.5).
    private let sharedStateLock = NSLock()
    private var _connectionLog: [String] = []
    private(set) var connectionLog: [String] {
        get { sharedStateLock.withLock { _connectionLog } }
        set { sharedStateLock.withLock { _connectionLog = newValue } }
    }
    /// Browser tool catalog: provided by the extension, with a bundled copy as fallback.
    private(set) var browserTools: [JSONObject] = {
        guard let url = Bundle.main.url(forResource: "tools", withExtension: "json"),
              let d = try? Data(contentsOf: url), let arr = JSON.parseAny(d) as? [JSONObject] else { return [] }
        return arr
    }()
    private var bridgeTokens: [String: String] = [:]          // bridge token -> conversation id
    private var pendingTools: [String: (run: Run, toolId: String, client: WSClient?, emit: Bool, completion: (ToolOutcome) -> Void)] = [:]
    private var pendingCalls: [String: (client: WSClient, completion: (Result<Any, AgentError>) -> Void)] = [:]
    private var runs: [String: Run] = [:]
    /// Per conversation: has it read web content / local data? Used for approval safeguards.
    private var taint: [String: (web: Bool, local: Bool)] = [:]

    var claude: ClaudeProvider!
    var chatgpt: ChatGPTProvider!
    private var providers: [Provider] { [claude, chatgpt] }

    /// Observed by the status UI (called on the main thread).
    var onStatusChange: (() -> Void)?
    private var _lastProviderStatus: [JSONObject] = []
    private(set) var lastProviderStatus: [JSONObject] {
        get { sharedStateLock.withLock { _lastProviderStatus } }
        set { sharedStateLock.withLock { _lastProviderStatus = newValue } }
    }
    var extensionConnected: Bool { !instances.isEmpty }

    private init() {
        server = WebSocketServer(queue: queue)
        claude = ClaudeProvider(hub: self)
        chatgpt = ChatGPTProvider(hub: self)
    }

    // MARK: lifecycle

    func start() {
        Paths.ensure(Paths.support)
        server.onClient = { [weak self] c in self?.accept(c) }
        server.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let p):
                self.port = p
                self.writeConnectionFile()
                Log.helper.info("helper listening on 127.0.0.1:\(p, privacy: .public)")
            case .failure(let e):
                Log.helper.error("helper failed to listen: \(String(describing: e), privacy: .public)")
            }
            self.notifyStatus()
        }
        SettingsStore.shared.onChange = { [weak self] old, new in self?.settingsChanged(old, new) }
        queue.async { self.refreshProviders(refresh: true) }
    }

    func stop() {
        // Only remove the connection file if it is ours (a newer instance may have replaced it).
        if let d = try? Data(contentsOf: Paths.connectionFile), let o = JSON.parse(d), o["pid"] as? Int == Int(getpid()) {
            try? FileManager.default.removeItem(at: Paths.connectionFile)
        }
        claude.shutdown()
    }

    private func writeConnectionFile() {
        let info: JSONObject = ["port": Int(port), "token": token, "pid": Int(getpid()), "version": 2]
        do { try Paths.writePrivate(JSON.data(info), to: Paths.connectionFile) }
        catch { Log.helper.error("could not write connection file") }
    }

    func notifyStatus() {
        let connected = Set(instances.keys)
        DispatchQueue.main.async {
            ProfileRegistry.shared.setConnected(connected)
            self.onStatusChange?()
        }
    }

    private func logConnection(_ s: String) {
        let f = ISO8601DateFormatter()
        connectionLog.append("\(f.string(from: Date())) \(s)")
        if connectionLog.count > 60 { connectionLog.removeFirst(connectionLog.count - 60) }
    }

    // MARK: clients

    private func accept(_ c: WSClient) {
        clients.insert(c)
        c.onMessage = { [weak self] client, msg in self?.handle(client, msg) }
        c.onClose = { [weak self] client in self?.queue.async { self?.closed(client) } }
        // Unauthenticated clients must say hello promptly.
        queue.asyncAfter(deadline: .now() + 10) { [weak c] in
            if let c, c.role == "unauthenticated" { c.close() }
        }
    }

    private func closed(_ c: WSClient) {
        clients.remove(c)
        if let profile = c.profileId, instances[profile]?.client === c {
            instances[profile] = nil
            logConnection("disconnect \(profile.prefix(8))")
            // Fail tool calls and RPCs that were waiting for this instance.
            for (callId, p) in pendingTools where p.client === c {
                pendingTools[callId] = nil
                p.run.pendingToolCalls.remove(callId)
                if p.emit { emit(p.run, ["kind": "tool_end", "messageId": p.run.messageId, "toolId": p.toolId, "status": "error", "detail": "Safari extension disconnected"]) }
                p.completion(.error("The Safari extension disconnected while running this action (Safari may have reloaded the extension). Check the page state and try again."))
            }
            for (id, p) in pendingCalls where p.client === c {
                pendingCalls[id] = nil
                p.completion(.failure(AgentError("disconnected", "Safari disconnected.")))
            }
            notifyStatus()
        }
    }

    private func handle(_ c: WSClient, _ msg: JSONObject) {
        let type = msg["type"] as? String ?? ""
        if c.role == "unauthenticated" {
            guard type == "hello" else { c.close(); return }
            authenticate(c, msg)
            return
        }
        if c.role == "extension", let p = c.profileId { instances[p]?.lastActive = Date() }
        switch (c.role, type) {
        case ("extension", "tool_result"), ("driver", "tool_result"):
            toolResult(msg)
        case ("extension", "call_result"):
            guard let id = msg["id"] as? String, let p = pendingCalls.removeValue(forKey: id) else { return }
            if let e = msg["error"] as? String { p.completion(.failure(AgentError("call_failed", e))) }
            else { p.completion(.success(msg["result"] ?? NSNull())) }
        case ("extension", "event"):
            instanceEvent(c, msg)
        case ("extension", "approval_pending"):
            // Mirror approval prompts to local test drivers (they can answer via approval.respond).
            for d in clients where d.role == "driver" { d.send(msg) }
        case (_, "req") where c.role == "extension" || c.role == "driver":
            let id = msg["id"] as? String ?? ""
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? JSONObject ?? [:]
            handleRequest(method, params, from: c) { result in
                switch result {
                case .success(let v): c.send(["type": "res", "id": id, "result": v])
                case .failure(let e): c.send(["type": "res", "id": id, "error": ["message": e.message, "code": e.code]])
                }
            }
        case ("mcp", "tools_list"):
            c.send(["type": "tools", "id": msg["id"] ?? "", "tools": toolsFor(conversationId: c.conversationId)])
        case ("mcp", "tool_call"):
            bridgeToolCall(c, msg)
        default:
            break
        }
    }

    private func authenticate(_ c: WSClient, _ msg: JSONObject) {
        let role = msg["role"] as? String ?? ""
        let presented = msg["token"] as? String ?? ""
        switch role {
        case "extension", "driver":
            guard constantTimeEqual(presented, token) else {
                c.send(["type": "rejected", "reason": "Invalid helper token."]); c.close(); return
            }
            c.role = role
            if role == "extension" {
                let profile = sanitizeProfileId(msg["profile"] as? String)
                c.profileId = profile
                // One connection per profile: a reconnect of the same instance replaces the old one,
                // but instances of different profiles never displace each other.
                if let old = instances[profile], old.client !== c { old.client.close() }
                instances[profile] = ExtensionInstance(client: c, profileId: profile, version: msg["version"] as? String ?? "")
                if let t = msg["tools"] as? [JSONObject], !t.isEmpty { browserTools = t }
                logConnection("connect \(profile.prefix(8))")
                c.send(["type": "welcome", "version": 2, "profileId": profile])
                DispatchQueue.main.async { ProfileRegistry.shared.instanceConnected(profile) }
                queue.asyncAfter(deadline: .now() + 0.05) { self.pushConfig(to: profile) }
                SessionSharing.shared.instanceConnected(profile)
                notifyStatus()
            } else {
                c.send(["type": "welcome", "version": 2])
            }
        case "mcp":
            guard let conv = bridgeTokens.first(where: { constantTimeEqual($0.key, presented) })?.value else {
                c.send(["type": "rejected", "reason": "Invalid bridge token."]); c.close(); return
            }
            c.role = "mcp"
            c.conversationId = conv
            c.send(["type": "welcome", "version": 2])
        default:
            c.send(["type": "rejected", "reason": "Unknown role."]); c.close()
        }
    }

    private func sanitizeProfileId(_ s: String?) -> String {
        let v = (s ?? "default").trimmingCharacters(in: .whitespaces)
        let ok = !v.isEmpty && v.count <= 64 && v.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return ok ? v : "default"
    }

    /// The instance used when no profile is specified (debug driver, status): most recently active.
    var primaryInstance: ExtensionInstance? { instances.values.max { $0.lastActive < $1.lastActive } }

    func instance(_ profileId: String?) -> ExtensionInstance? {
        if let p = profileId, let i = instances[p] { return i }
        return nil
    }

    private func drivers() -> [WSClient] { clients.filter { $0.role == "driver" } }

    /// Send to every extension instance (and drivers).
    func broadcastAll(_ msg: JSONObject) {
        for i in instances.values { i.client.send(msg) }
        for d in drivers() { d.send(msg) }
    }

    private func sendConversations() {
        for i in instances.values {
            i.client.send(["type": "conversations", "conversations": conversationList(for: i.profileId)])
        }
    }

    private func conversationList(for profile: String?) -> [JSONObject] {
        let shared = SettingsStore.shared.current.agent.sharedHistory
        return store.list().filter { shared || profile == nil || $0.profileId == nil || $0.profileId == profile }.map { $0.summaryJSON() }
    }

    /// Request/response call into one extension instance (e.g. open a URL in that profile).
    func callInstance(_ profileId: String, _ method: String, _ params: JSONObject = [:], timeout: Double = 10, completion: @escaping (Result<Any, AgentError>) -> Void) {
        guard let inst = instances[profileId] else {
            return completion(.failure(AgentError("not_connected", "Orbit isn't connected to this Safari profile right now.")))
        }
        let id = UUID().uuidString
        pendingCalls[id] = (inst.client, completion)
        inst.client.send(["type": "call", "id": id, "method": method, "params": params])
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let p = self?.pendingCalls.removeValue(forKey: id) { p.completion(.failure(AgentError("timeout", "Safari did not respond in time."))) }
        }
    }

    func callInstance(_ profileId: String, _ method: String, _ params: JSONObject = [:], timeout: Double = 10) async -> Result<Any, AgentError> {
        await withCheckedContinuation { cont in
            queue.async { self.callInstance(profileId, method, params, timeout: timeout) { cont.resume(returning: $0) } }
        }
    }

    // MARK: configuration pushed to the extension instances

    func pushConfig(to profile: String? = nil) {
        let s = SettingsStore.shared.current
        for i in instances.values where profile == nil || i.profileId == profile {
            i.client.send(["type": "config", "config": s.extensionConfig(for: i.profileId)])
        }
    }

    private func settingsChanged(_ old: AppSettings, _ new: AppSettings) {
        if old.routing != new.routing || old.sharing != new.sharing || old.profiles != new.profiles || old.agent.computerAccess != new.agent.computerAccess || old.history != new.history {
            pushConfig()
        }
        if old.sharing != new.sharing { SessionSharing.shared.settingsChanged(old.sharing, new.sharing) }
        if old.agent.sharedHistory != new.agent.sharedHistory { sendConversations() }
    }

    // MARK: events from extension instances

    private func instanceEvent(_ c: WSClient, _ msg: JSONObject) {
        guard let profile = c.profileId else { return }
        let name = msg["name"] as? String ?? ""
        let data = msg["data"] as? JSONObject ?? [:]
        switch name {
        case "window_focused":
            instances[profile]?.lastFocused = Date()
            SessionSharing.shared.profileActive(profile)
            let size = (data["width"] as? Double).flatMap { w in (data["height"] as? Double).map { CGSize(width: w, height: $0) } }
            let left = data["left"] as? Double
            DispatchQueue.main.async { ProfileRegistry.shared.profileFocused(profile, left: left, size: size) }
        case "window_created":
            DispatchQueue.main.async { ProfileRegistry.shared.windowCreated(profile) }
        case "visit":
            HistoryStore.shared.add(profileId: profile, url: data["url"] as? String ?? "", title: data["title"] as? String ?? "")
        case "cookies_changed":
            SessionSharing.shared.cookiesChanged(profile: profile, domain: data["domain"] as? String ?? "")
        default:
            break
        }
    }

    // MARK: requests

    typealias Reply = (Result<Any, AgentError>) -> Void

    private func handleRequest(_ method: String, _ p: JSONObject, from c: WSClient, reply: @escaping Reply) {
        let profile = c.role == "extension" ? c.profileId : (p["profile"] as? String)
        if method.hasPrefix("route.") { return Router.shared.handle(method, p, profile: profile, reply: reply) }
        if method.hasPrefix("sessions.") { return SessionSharing.shared.handle(method, p, profile: profile, reply: reply) }
        switch method {
        case "providers.list":
            refreshProviders(refresh: p["refresh"] as? Bool ?? false) { reply(.success($0)) }
        case "conversations.list":
            reply(.success(conversationList(for: profile)))
        case "conversations.get":
            guard let id = p["id"] as? String, let conv = store.get(id) else { return reply(.failure(AgentError("not_found", "Conversation not found."))) }
            reply(.success(conv.json()))
        case "conversations.delete":
            guard let id = p["id"] as? String else { return reply(.failure(AgentError("bad_request", "Missing id."))) }
            if let r = runs[id] { cancel(r) }
            providers.forEach { $0.forget(conversationId: id) }
            store.delete(id)
            taint[id] = nil
            reply(.success(["ok": true]))
            sendConversations()
        case "chat.send":
            chatSend(p, profile: profile ?? "default", reply: reply)
        case "chat.cancel":
            if let id = p["conversationId"] as? String, let r = runs[id] { cancel(r) }
            reply(.success(["ok": true]))
        case "chat.running":
            let r = runs.values.first { profile == nil || $0.profileId == profile }
            reply(.success(["conversationId": r?.conversationId as Any]))
        case "chatgpt.signin":
            chatgpt.signIn { [weak self] result in
                self?.queue.async {
                    switch result {
                    case .success: reply(.success(["ok": true]))
                    case .failure(let e): reply(.failure(e))
                    }
                    self?.refreshProviders(refresh: true)
                }
            }
        case "chatgpt.signout":
            chatgpt.signOut { [weak self] in
                self?.queue.async { reply(.success(["ok": true])); self?.refreshProviders(refresh: true) }
            }
        case "claude.login":
            ClaudeCLI.openLoginInTerminal()
            reply(.success(["ok": true]))
        case "approval.respond":
            // Test driver answering an approval shown in a panel.
            for i in instances.values { i.client.send(["type": "approval_response", "id": p["id"] ?? "", "allow": p["allow"] as? Bool ?? false]) }
            reply(.success(["ok": true]))
        case "approval.relay":
            // An instance acting in another profile asks the chat's own panel for approval.
            guard let owner = p["ownerProfile"] as? String else { return reply(.failure(AgentError("bad_request", "Missing owner."))) }
            requestApproval(profileId: owner, conversationId: p["conversationId"] as? String ?? "", tool: p["tool"] as? String ?? "", summary: p["summary"] as? String ?? "", reason: p["reason"] as? String ?? "") { ok in
                reply(.success(["allow": ok]))
            }
        case "profiles.list":
            let s = SettingsStore.shared.current
            reply(.success(["profileId": profile as Any, "profiles": s.orderedProfiles.map { ["id": $0.id, "name": $0.name, "symbol": $0.symbol, "color": $0.color, "connected": instances[$0.id] != nil] }]))
        case "settings.agent":
            let a = SettingsStore.shared.current.agent
            reply(.success(["computerAccess": a.computerAccess, "folders": a.folders, "allowCommands": a.allowCommands]))
        case "settings.update_agent":
            SettingsStore.shared.update { s in
                if let v = p["computerAccess"] as? String, ["none", "folders", "full"].contains(v) { s.agent.computerAccess = v }
                if let v = p["allowCommands"] as? Bool { s.agent.allowCommands = v }
                if let rm = p["removeFolder"] as? String { s.agent.folders.removeAll { $0 == rm } }
            }
            let a = SettingsStore.shared.current.agent
            reply(.success(["computerAccess": a.computerAccess, "folders": a.folders, "allowCommands": a.allowCommands]))
        case "folders.choose":
            DispatchQueue.main.async {
                let chosen = FolderPicker.choose()
                if !chosen.isEmpty { SettingsStore.shared.update { s in for f in chosen where !s.agent.folders.contains(f) { s.agent.folders.append(f) } } }
                reply(.success(["folders": SettingsStore.shared.current.agent.folders]))
            }
        case "app.open_settings":
            DispatchQueue.main.async { AppDelegate.shared?.openSettings(section: p["section"] as? String) }
            reply(.success(["ok": true]))
        // ---- test driver (local only, token protected) ----
        case "debug.state":
            reply(.success([
                "extensionConnected": !instances.isEmpty,
                "instances": instances.values.map { ["profile": $0.profileId, "version": $0.version, "connectedAt": $0.connectedAt.timeIntervalSince1970, "lastActive": $0.lastActive.timeIntervalSince1970] },
                "connectionLog": connectionLog,
                "tools": browserTools.count,
                "running": runs.keys.first as Any,
            ]))
        case "debug.agent_settings":
            // Local test driver only: set computer access without the folder chooser.
            guard c.role == "driver" else { return reply(.failure(AgentError("forbidden", "Not allowed."))) }
            SettingsStore.shared.update { s in
                if let v = p["computerAccess"] as? String { s.agent.computerAccess = v }
                if let f = p["folders"] as? [String] { s.agent.folders = f }
                if let v = p["allowCommands"] as? Bool { s.agent.allowCommands = v }
            }
            reply(.success(["ok": true]))
        case "debug.permissions":
            // Local test driver only: permission status, and optionally show a sample notice.
            guard c.role == "driver" else { return reply(.failure(AgentError("forbidden", "Not allowed."))) }
            DispatchQueue.global().async {
                let auto = Permissions.automation(ask: false)
                DispatchQueue.main.async {
                    if p["showNotice"] as? Bool == true { AppDelegate.shared?.notify(.automation("Needed to open the link in “University”")) }
                    reply(.success(["accessibility": AXIsProcessTrusted(), "automation": String(describing: auto)]))
                }
            }
        case "debug.history_forget":
            guard c.role == "driver", let host = p["host"] as? String else { return reply(.failure(AgentError("forbidden", "Not allowed."))) }
            HistoryStore.shared.forget(host: host)
            reply(.success(["ok": true]))
        case "debug.safari_db":
            guard c.role == "driver" else { return reply(.failure(AgentError("forbidden", "Not allowed."))) }
            reply(.success(SafariProfileStore.describeSchema()))
        case "debug.focus_profile", "debug.safari_profiles":
            // Local test driver only.
            guard c.role == "driver" else { return reply(.failure(AgentError("forbidden", "Not allowed."))) }
            if method == "debug.safari_profiles" {
                DispatchQueue.main.async {
                    ProfileRegistry.shared.syncFromSafari()
                    let s = SettingsStore.shared.current
                    let front = SafariAX.windowProfiles().first?.name
                    reply(.success(["front": front as Any, "colorSource": ProfileRegistry.shared.colorSource,
                                    "profiles": s.listedProfiles.map { ["id": String($0.id.prefix(12)), "name": $0.name, "symbol": $0.symbol, "color": $0.color, "default": $0.isSafariDefault as Any] }]))
                }
                return
            }
            let id = p["profileId"] as? String ?? ""
            Task {
                let r = await SafariController.focus(profileId: id)
                let front = await MainActor.run { SafariAX.windowProfiles().first?.name }
                if case .fallback(let why) = r { reply(.success(["ok": false, "why": why.title, "front": front as Any])) } else { reply(.success(["ok": true, "front": front as Any])) }
            }
        case "debug.call":
            // Test driver: call an extension instance method (e.g. "caps", "windows").
            guard let inst = instance(p["profile"] as? String) ?? primaryInstance else { return reply(.failure(AgentError("no_extension", "Extension not connected."))) }
            callInstance(inst.profileId, p["method"] as? String ?? "", p["params"] as? JSONObject ?? [:], timeout: p["timeout"] as? Double ?? 15) { r in
                switch r { case .success(let v): reply(.success(v)); case .failure(let e): reply(.failure(e)) }
            }
        case "debug.panel", "debug.panel_send", "debug.probe", "debug.settings", "debug.toggle":
            guard let inst = instance(p["profile"] as? String) ?? primaryInstance else { return reply(.failure(AgentError("no_extension", "Extension not connected."))) }
            let m: [String: String] = ["debug.panel": "panel", "debug.panel_send": "debug_send", "debug.probe": "debug_probe", "debug.settings": "debug_settings", "debug.toggle": "debug_toggle"]
            var params = p
            params["profile"] = nil
            callInstance(inst.profileId, m[method]!, params, timeout: 15) { r in
                switch r { case .success(let v): reply(.success(v)); case .failure(let e): reply(.failure(e)) }
            }
        case "debug.tool":
            // Test driver: run a browser tool directly (no AI), e.g. to verify page state.
            guard let name = p["name"] as? String else { return reply(.failure(AgentError("bad_request", "Missing name."))) }
            let target = (instance(p["profile"] as? String) ?? primaryInstance)?.profileId ?? "default"
            let run = Run(conversationId: "debug-\(UUID().uuidString.prefix(8))", messageId: "debug", provider: "debug", profileId: target)
            run.finished = true
            run.tabScope = "all"
            run.approvalMode = p["approvalMode"] as? String ?? "never"
            executeTool(run: run, name: name, args: p["args"] as? JSONObject ?? [:], emitEvents: false) { out in
                self.queue.async { reply(.success(["isError": out.isError, "content": out.content])) }
            }
        default:
            reply(.failure(AgentError("unknown_method", "Unknown method \(method).")))
        }
    }

    func refreshProviders(refresh: Bool, completion: (([JSONObject]) -> Void)? = nil) {
        // Answer immediately from the last known status; refresh in the background.
        if !refresh, !lastProviderStatus.isEmpty, !lastProviderStatus.contains(where: { $0["state"] as? String == "checking" }) {
            completion?(lastProviderStatus)
            refreshProvidersNow(refresh: false, completion: nil)
            return
        }
        refreshProvidersNow(refresh: refresh, completion: completion)
    }

    private func refreshProvidersNow(refresh: Bool, completion: (([JSONObject]) -> Void)?) {
        let group = DispatchGroup()
        var results: [String: JSONObject] = [:]
        let lock = NSLock()
        for p in providers {
            group.enter()
            p.status(refresh: refresh) { s in
                lock.lock(); results[p.id] = s; lock.unlock()
                group.leave()
            }
        }
        var delivered = false
        let deliver = {
            guard !delivered else { return }
            delivered = true
            lock.lock()
            let list: [JSONObject] = ["claude", "chatgpt"].map { id in
                results[id] ?? ["id": id, "name": id == "claude" ? "Claude" : "ChatGPT", "available": false, "state": "checking", "detail": "Checking…", "models": [] as [JSONObject]]
            }
            lock.unlock()
            let changed = JSON.string(list) != JSON.string(self.lastProviderStatus)
            self.lastProviderStatus = list
            completion?(list)
            if changed { self.broadcastAll(["type": "providers", "providers": list]) }
            DispatchQueue.main.async { self.onStatusChange?() }
        }
        group.notify(queue: queue) { deliver() }
        // A provider that hangs (e.g. waiting on a keychain prompt) must not block the other.
        queue.asyncAfter(deadline: .now() + 8) {
            deliver()
            group.notify(queue: self.queue) { if delivered { self.refreshProvidersLate(results: results, lock: lock) } }
        }
    }

    /// Broadcast the final status once a slow provider finished after the timeout.
    private func refreshProvidersLate(results: [String: JSONObject], lock: NSLock) {
        lock.lock()
        let list = ["claude", "chatgpt"].compactMap { results[$0] }
        lock.unlock()
        guard list.count == 2, JSON.string(list) != JSON.string(lastProviderStatus) else { return }
        lastProviderStatus = list
        broadcastAll(["type": "providers", "providers": list])
        DispatchQueue.main.async { self.onStatusChange?() }
    }

    private func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    private func chatSend(_ p: JSONObject, profile: String, reply: @escaping Reply) {
        guard !runs.values.contains(where: { $0.profileId == profile }) else {
            return reply(.failure(AgentError("busy", "A task is already running. Stop it before sending a new message.")))
        }
        let text = (p["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return reply(.failure(AgentError("bad_request", "Empty message."))) }
        guard text.count <= 100_000 else { return reply(.failure(AgentError("bad_request", "Message is too long."))) }
        let providerId = p["provider"] as? String ?? "claude"
        guard let prov = provider(providerId) else { return reply(.failure(AgentError("bad_request", "Unknown provider."))) }
        let status = lastProviderStatus.first { $0["id"] as? String == providerId }
        if let status, status["available"] as? Bool != true {
            return reply(.failure(AgentError("provider_unavailable", status["detail"] as? String ?? "\(providerId) is not available.")))
        }
        let model = p["model"] as? String
        var conv: Conversation
        if let id = p["conversationId"] as? String, let existing = store.get(id), existing.provider == providerId {
            conv = existing
        } else {
            conv = store.create(provider: providerId, model: model, title: String(text.prefix(60)), profileId: profile)
        }
        if let model { conv.model = model }
        if conv.profileId == nil { conv.profileId = profile }
        let userId = (p["userMessageId"] as? String) ?? "u\(Int(Date().timeIntervalSince1970 * 1000))"
        conv.messages.append(UIMessage(id: userId, role: "user", blocks: [Block(type: "text", text: text)], createdAt: Date().timeIntervalSince1970 * 1000))
        conv.updatedAt = Date().timeIntervalSince1970 * 1000
        store.update(conv)
        reply(.success(["conversationId": conv.id, "title": conv.title]))
        sendConversations()

        let run = Run(conversationId: conv.id, messageId: "m\(UUID().uuidString.prefix(12).lowercased())", provider: providerId, profileId: profile)
        if let s = p["tabScope"] as? String, ["tab", "window", "all"].contains(s) { run.tabScope = s }
        if let m = p["approvalMode"] as? String, ["sensitive", "always", "never"].contains(m) { run.approvalMode = m }
        // Conversations that already contain browser or file tool results stay marked.
        if taint[conv.id] == nil {
            let names = conv.messages.flatMap { $0.blocks.compactMap { $0.type == "tool" ? $0.name : nil } }
            taint[conv.id] = (names.contains { !NativeTools.handles($0) }, names.contains { NativeTools.readsLocalData($0) })
        }
        // Bind the task to the tab the user was viewing when they sent it.
        if let ctx = p["context"] as? JSONObject, let tabId = ctx["tabId"] as? Int {
            instances[profile]?.client.send(["type": "bind_tab", "conversationId": conv.id, "tabId": tabId, "windowId": ctx["windowId"] ?? NSNull()])
        }
        runs[conv.id] = run
        emit(run, ["kind": "message_start", "messageId": run.messageId])
        let env = Prompts.Environment(
            profileName: SettingsStore.shared.current.profile(profile)?.name,
            otherProfiles: run.tabScope == "all" ? SettingsStore.shared.current.orderedProfiles.filter { $0.id != profile }.map(\.name) : [],
            tabScope: run.tabScope,
            computerAccess: SettingsStore.shared.current.agent.computerAccess,
            folders: SettingsStore.shared.current.agent.folders)
        let fullText = Prompts.userMessage(text: text, context: p["context"] as? JSONObject, env: env)
        prov.startTurn(conversation: conv, userText: fullText, model: model, effort: p["effort"] as? String, sink: TurnSink(hub: self, run: run))
    }

    // MARK: runs & events

    func emit(_ run: Run, _ event: JSONObject) {
        guard !run.finished || event["kind"] as? String == "done" else { return }
        if var conv = store.get(run.conversationId) {
            conv.apply(event)
            store.update(conv, persist: event["kind"] as? String == "done" || event["kind"] as? String == "tool_end")
        }
        let msg: JSONObject = ["type": "event", "conversationId": run.conversationId, "event": event]
        instances[run.profileId]?.client.send(msg)
        for d in drivers() { d.send(msg) }
    }

    func finishRun(_ run: Run, error: AgentError?, cancelled: Bool) {
        guard !run.finished else { return }
        if let error, !(cancelled || run.cancelled) {
            emit(run, ["kind": "error", "messageId": run.messageId, "text": error.message, "code": error.code])
        }
        emit(run, ["kind": "done", "messageId": run.messageId, "cancelled": cancelled || run.cancelled])
        run.finished = true
        runs[run.conversationId] = nil
        for (callId, p) in pendingTools where p.run === run { pendingTools[callId] = nil }
    }

    private func cancel(_ run: Run) {
        guard !run.cancelled else { return }
        run.cancelled = true
        // Unblock tool calls waiting on the browser.
        for (callId, p) in pendingTools where p.run === run {
            pendingTools[callId] = nil
            emit(run, ["kind": "tool_end", "messageId": run.messageId, "toolId": p.toolId, "status": "error", "detail": "Cancelled"])
            p.completion(.error("The user stopped the task."))
        }
        NativeTools.shared.cancel(conversationId: run.conversationId)
        run.cancelHandler?()
        // Safety net: if the provider does not wind down, finish anyway.
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            if !run.finished { self?.finishRun(run, error: nil, cancelled: true) }
        }
    }

    func setClaudeSession(conversationId: String, sessionId: String) {
        guard var c = store.get(conversationId), c.claudeSessionId != sessionId else { return }
        c.claudeSessionId = sessionId
        store.update(c)
    }

    func activeRun(_ conversationId: String) -> Run? { runs[conversationId] }

    // MARK: approvals

    /// Ask the user in the chat's own panel. Denies when no panel can ask.
    func requestApproval(profileId: String, conversationId: String, tool: String, summary: String, reason: String, completion: @escaping (Bool) -> Void) {
        callInstance(profileId, "approval", ["conversationId": conversationId, "tool": tool, "summary": summary, "reason": reason], timeout: 5 * 60 + 5) { r in
            if case .success(let v) = r, let o = v as? JSONObject, o["allow"] as? Bool == true { completion(true) } else { completion(false) }
        }
    }

    // MARK: tool catalog

    /// Tools offered to the model for a conversation: browser tools plus, when the
    /// user allowed it, local file (and command) tools.
    func toolsFor(conversationId: String?) -> [JSONObject] {
        browserTools + NativeTools.catalog(SettingsStore.shared.current.agent)
    }

    /// Changes when the offered tool set changes (Claude sessions restart to pick it up).
    var toolsetKey: String {
        let a = SettingsStore.shared.current.agent
        return "\(a.computerAccess)-\(a.allowCommands)"
    }

    func toolCatalog(conversationId: String?) -> [JSONObject] { queue.sync { toolsFor(conversationId: conversationId) } }

    // MARK: MCP bridge

    func issueBridgeToken(conversationId: String) -> String {
        // One stable token per conversation while the helper runs.
        if let existing = bridgeTokens.first(where: { $0.value == conversationId })?.key { return existing }
        let t = Random.token()
        bridgeTokens[t] = conversationId
        return t
    }

    private func bridgeToolCall(_ c: WSClient, _ msg: JSONObject) {
        let reqId = msg["id"] ?? ""
        guard let conv = c.conversationId, let run = runs[conv], !run.cancelled else {
            c.send(["type": "tool_result", "id": reqId, "result": ["content": [["type": "text", "text": "No task is running; the user may have stopped it."]], "isError": true]])
            return
        }
        let name = msg["name"] as? String ?? ""
        let args = msg["args"] as? JSONObject ?? [:]
        executeTool(run: run, name: name, args: args) { out in
            c.send(["type": "tool_result", "id": reqId, "result": ["content": out.content, "isError": out.isError]])
        }
    }

    // MARK: tools

    func executeTool(run: Run, name: String, args: JSONObject, emitEvents: Bool = true, completion: @escaping (ToolOutcome) -> Void) {
        if run.cancelled { return completion(.error("The user stopped the task.")) }
        let isNative = NativeTools.handles(name)
        guard isNative || browserTools.isEmpty || browserTools.contains(where: { $0["name"] as? String == name }) else {
            return completion(.error("Unknown tool \(name)."))
        }
        run.toolSeq += 1
        let toolId = "t\(run.toolSeq)"
        if emitEvents {
            emit(run, ["kind": "tool_start", "messageId": run.messageId, "toolId": toolId, "name": name, "summary": ToolSummary.describe(name, args)])
        }
        let finish: (ToolOutcome, String?) -> Void = { [weak self] out, detail in
            guard let self else { return }
            self.queue.async {
                if emitEvents {
                    let denied = out.isError && out.text.hasPrefix("The user denied")
                    self.emit(run, ["kind": "tool_end", "messageId": run.messageId, "toolId": toolId, "status": denied ? "denied" : (out.isError ? "error" : "done"), "detail": detail ?? ""])
                }
                completion(out)
            }
        }
        if isNative {
            let ctx = NativeTools.Context(conversationId: run.conversationId, profileId: run.profileId, approvalMode: run.approvalMode,
                                          sawWebContent: taint[run.conversationId]?.web ?? false)
            NativeTools.shared.execute(name: name, args: args, context: ctx) { [weak self] out, detail in
                self?.queue.async {
                    if !out.isError, NativeTools.readsLocalData(name) { self?.markTaint(run.conversationId, local: true) }
                    finish(out, detail)
                }
            }
            return
        }
        // Browser tool: pick the extension instance (profile) that owns the tab.
        var targetProfile = run.profileId
        var toolArgs = args
        if let requested = args["profile"] as? String, !requested.isEmpty {
            toolArgs["profile"] = nil
            guard let pid = ProfileRegistry.resolve(requested, in: SettingsStore.shared.current) else {
                return finish(.error("There is no Safari profile named “\(requested)”."), nil)
            }
            if pid != run.profileId && run.tabScope != "all" {
                return finish(.error("The user has not allowed access to other Safari profiles. Ask them to choose “All windows and profiles” under Browser access in the panel."), nil)
            }
            targetProfile = pid
        }
        if name == "tabs_list" && run.tabScope == "all" && args["profile"] == nil {
            return listTabsAcrossProfiles(run: run, finish: finish)
        }
        guard let inst = instances[targetProfile] else {
            let msg = targetProfile == run.profileId
                ? "The Safari extension is not connected to Orbit. Ask the user to open the Orbit panel in Safari."
                : "Orbit isn't connected to that Safari profile right now (it connects while one of its windows is in use)."
            return finish(.error(msg), "Extension not connected")
        }
        let callId = UUID().uuidString
        run.pendingToolCalls.insert(callId)
        pendingTools[callId] = (run, toolId, inst.client, emitEvents, { out in completion(out) })
        let guardInfo: JSONObject = ["exfil": taint[run.conversationId]?.local ?? false]
        inst.client.send(["type": "tool_call", "callId": callId, "conversationId": run.conversationId, "name": name, "args": toolArgs,
                          "ownerProfile": run.profileId, "scope": run.tabScope, "approvalMode": run.approvalMode, "guard": guardInfo])
        markTaint(run.conversationId, web: true)
        // Approval prompts can take up to 5 minutes.
        queue.asyncAfter(deadline: .now() + 6 * 60) { [weak self] in
            guard let self, let p = self.pendingTools[callId] else { return }
            self.pendingTools[callId] = nil
            if p.emit { self.emit(run, ["kind": "tool_end", "messageId": run.messageId, "toolId": toolId, "status": "error", "detail": "Timed out"]) }
            p.completion(.error("The browser did not respond to this action in time."))
        }
    }

    private func markTaint(_ conv: String, web: Bool = false, local: Bool = false) {
        let t = taint[conv] ?? (false, false)
        taint[conv] = (t.web || web, t.local || local)
    }

    private func listTabsAcrossProfiles(run: Run, finish: @escaping (ToolOutcome, String?) -> Void) {
        let settings = SettingsStore.shared.current
        let targets = instances.keys.sorted { a, b in
            if a == run.profileId { return true }
            if b == run.profileId { return false }
            return (settings.profile(a)?.order ?? 99) < (settings.profile(b)?.order ?? 99)
        }
        var parts: [String: String] = [:]
        let group = DispatchGroup()
        for pid in targets {
            guard let inst = instances[pid] else { continue }
            group.enter()
            let callId = UUID().uuidString
            pendingTools[callId] = (run, "list", inst.client, false, { out in
                parts[pid] = out.text
                group.leave()
            })
            inst.client.send(["type": "tool_call", "callId": callId, "conversationId": run.conversationId, "name": "tabs_list", "args": [:] as JSONObject,
                              "ownerProfile": run.profileId, "scope": "all", "approvalMode": run.approvalMode])
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                if let p = self?.pendingTools.removeValue(forKey: callId) { p.completion(.error("(no answer)")) }
            }
        }
        markTaint(run.conversationId, web: true)
        group.notify(queue: queue) {
            let text = targets.map { pid -> String in
                let name = settings.profile(pid)?.name ?? "Profile"
                return "## Safari profile “\(name)”\(pid == run.profileId ? " (this chat's profile)" : "") — pass profile=\"\(name)\" to use these tabs\n\(parts[pid] ?? "(no answer)")"
            }.joined(separator: "\n\n")
            let missing = settings.orderedProfiles.filter { self.instances[$0.id] == nil }.map(\.name)
            finish(.ok(text + (missing.isEmpty ? "" : "\n\n(Not connected right now: \(missing.joined(separator: ", ")).)")), "Listed tabs in \(targets.count) profiles")
        }
    }

    private func toolResult(_ msg: JSONObject) {
        guard let callId = msg["callId"] as? String, let p = pendingTools[callId] else { return }
        pendingTools[callId] = nil
        p.run.pendingToolCalls.remove(callId)
        let r = msg["result"] as? JSONObject ?? [:]
        let content = (r["content"] as? [JSONObject]) ?? [["type": "text", "text": "(no result)"]]
        let isError = r["isError"] as? Bool ?? false
        let out = ToolOutcome(content: content, isError: isError)
        let summary = msg["summary"] as? String
        if p.emit {
            let denied = isError && out.text.hasPrefix("The user denied")
            emit(p.run, ["kind": "tool_end", "messageId": p.run.messageId, "toolId": p.toolId, "status": denied ? "denied" : (isError ? "error" : "done"), "detail": summary ?? ""])
        }
        p.completion(out)
    }
}

enum ToolSummary {
    static func describe(_ name: String, _ a: JSONObject) -> String {
        func s(_ k: String) -> String { (a[k] as? String).map { String($0.prefix(80)) } ?? "" }
        let inProfile = s("profile").isEmpty ? "" : " in \(s("profile"))"
        switch name {
        case "tabs_list": return "Listing tabs"
        case "read_page": return "Reading page structure\(inProfile)"
        case "get_page_text": return "Reading page text\(inProfile)"
        case "find": return "Finding “\(s("query"))”"
        case "get_selection": return "Reading selection"
        case "click": return "Clicking"
        case "type_text": return "Typing “\(s("text"))”"
        case "form_input": return "Setting a form field"
        case "press_key": return "Pressing \(s("key"))"
        case "scroll": return "Scrolling \(s("direction"))"
        case "navigate": return "Opening \(s("url"))"
        case "open_tab": return "Opening new tab \(s("url"))\(inProfile)"
        case "switch_tab": return "Switching tab\(inProfile)"
        case "close_tab": return "Closing tab"
        case "screenshot": return "Taking screenshot"
        case "wait": return "Waiting"
        default: return NativeTools.describe(name, a) ?? name
        }
    }
}
