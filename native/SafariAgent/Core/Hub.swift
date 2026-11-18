import Foundation
import AppKit

/// A running assistant turn for one conversation.
final class Run {
    let conversationId: String
    let messageId: String
    let provider: String
    var cancelled = false
    var finished = false
    var cancelHandler: (() -> Void)?
    var toolSeq = 0
    var pendingToolCalls: Set<String> = []

    init(conversationId: String, messageId: String, provider: String) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.provider = provider
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

/// Result of a browser tool call, as returned by the extension.
struct ToolOutcome {
    var content: [JSONObject]   // [{type:"text",text} | {type:"image",data,mediaType}]
    var isError: Bool

    static func error(_ msg: String) -> ToolOutcome { ToolOutcome(content: [["type": "text", "text": msg]], isError: true) }
    var text: String { content.compactMap { $0["text"] as? String }.joined(separator: "\n") }
}

protocol Provider: AnyObject {
    var id: String { get }
    func status(refresh: Bool, completion: @escaping (JSONObject) -> Void)
    func startTurn(conversation: Conversation, userText: String, model: String?, effort: String?, sink: TurnSink)
    func forget(conversationId: String)
}

final class Hub {
    static let shared = Hub()
    let queue = DispatchQueue(label: "dev.local.SafariAgent.hub")
    let server: WebSocketServer
    let store = ConversationStore()
    private(set) var token = Random.token()
    private(set) var port: UInt16 = 0

    private var clients = Set<WSClient>()
    private weak var extensionClient: WSClient?
    /// Tool catalog: provided by the connected extension, with a bundled copy as fallback.
    private(set) var currentTools: [JSONObject] = {
        guard let url = Bundle.main.url(forResource: "tools", withExtension: "json"),
              let d = try? Data(contentsOf: url), let arr = JSON.parseAny(d) as? [JSONObject] else { return [] }
        return arr
    }()
    private var bridgeTokens: [String: String] = [:]          // bridge token -> conversation id
    private var pendingTools: [String: (callId: String, run: Run, toolId: String, completion: (ToolOutcome) -> Void)] = [:]
    private var runs: [String: Run] = [:]

    var claude: ClaudeProvider!
    var chatgpt: ChatGPTProvider!
    private var providers: [Provider] { [claude, chatgpt] }

    /// Observed by the status window.
    var onStatusChange: (() -> Void)?
    private(set) var extensionConnected = false
    private(set) var lastProviderStatus: [JSONObject] = []

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
        let info: JSONObject = ["port": Int(port), "token": token, "pid": Int(getpid()), "version": 1]
        do { try Paths.writePrivate(JSON.data(info), to: Paths.connectionFile) }
        catch { Log.helper.error("could not write connection file") }
    }

    private func notifyStatus() {
        let ext = extensionClient != nil
        DispatchQueue.main.async {
            self.extensionConnected = ext
            self.onStatusChange?()
        }
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
        if c === extensionClient {
            extensionClient = nil
            // Fail tool calls that were waiting for the extension.
            for (callId, p) in pendingTools {
                pendingTools[callId] = nil
                p.run.pendingToolCalls.remove(callId)
                emit(p.run, ["kind": "tool_end", "messageId": p.run.messageId, "toolId": p.toolId, "status": "error", "detail": "Safari extension disconnected"])
                p.completion(.error("The Safari extension disconnected while running this action (the browser may have reloaded the extension). Check the page state and try again."))
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
        switch (c.role, type) {
        case ("extension", "tool_result"), ("driver", "tool_result"):
            toolResult(msg)
        case ("extension", "debug_probe_result"):
            if let id = msg["id"] as? String, let r = probeReplies.removeValue(forKey: id) { r(msg["result"] ?? NSNull()) }
        case ("extension", "approval_pending"):
            // Mirror approval prompts to local test drivers (they can answer via approval.respond).
            for d in clients where d.role == "driver" { d.send(msg) }
        case (_, "req") where c.role == "extension" || c.role == "driver":
            let id = msg["id"] as? String ?? ""
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? JSONObject ?? [:]
            handleRequest(method, params) { result in
                switch result {
                case .success(let v): c.send(["type": "res", "id": id, "result": v])
                case .failure(let e): c.send(["type": "res", "id": id, "error": ["message": e.message, "code": e.code]])
                }
            }
        case ("mcp", "tools_list"):
            c.send(["type": "tools", "id": msg["id"] ?? "", "tools": currentTools])
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
                if let old = extensionClient, old !== c { old.close() }
                extensionClient = c
                if let t = msg["tools"] as? [JSONObject], !t.isEmpty { currentTools = t }
                notifyStatus()
            }
            c.send(["type": "welcome", "version": 1])
        case "mcp":
            guard let conv = bridgeTokens.first(where: { constantTimeEqual($0.key, presented) })?.value else {
                c.send(["type": "rejected", "reason": "Invalid bridge token."]); c.close(); return
            }
            c.role = "mcp"
            c.conversationId = conv
            c.send(["type": "welcome", "version": 1])
        default:
            c.send(["type": "rejected", "reason": "Unknown role."]); c.close()
        }
    }

    private func broadcast(_ msg: JSONObject) {
        for c in clients where c.role == "extension" || c.role == "driver" { c.send(msg) }
    }

    // MARK: requests

    typealias Reply = (Result<Any, AgentError>) -> Void

    private func handleRequest(_ method: String, _ p: JSONObject, reply: @escaping Reply) {
        switch method {
        case "providers.list":
            refreshProviders(refresh: p["refresh"] as? Bool ?? false) { reply(.success($0)) }
        case "conversations.list":
            reply(.success(store.list().map { $0.summaryJSON() }))
        case "conversations.get":
            guard let id = p["id"] as? String, let c = store.get(id) else { return reply(.failure(AgentError("not_found", "Conversation not found."))) }
            reply(.success(c.json()))
        case "conversations.delete":
            guard let id = p["id"] as? String else { return reply(.failure(AgentError("bad_request", "Missing id."))) }
            if let r = runs[id] { cancel(r) }
            providers.forEach { $0.forget(conversationId: id) }
            store.delete(id)
            reply(.success(["ok": true]))
        case "chat.send":
            chatSend(p, reply: reply)
        case "chat.cancel":
            if let id = p["conversationId"] as? String, let r = runs[id] { cancel(r) }
            reply(.success(["ok": true]))
        case "chat.running":
            reply(.success(["conversationId": runs.keys.first as Any]))
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
            extensionClient?.send(["type": "approval_response", "id": p["id"] ?? "", "allow": p["allow"] as? Bool ?? false])
            reply(.success(["ok": true]))
        case "debug.panel":
            guard let ext = extensionClient else { return reply(.failure(AgentError("no_extension", "Extension not connected."))) }
            ext.send(["type": "panel", "open": p["open"] as? Bool ?? true])
            reply(.success(["ok": true]))
        case "debug.panel_send":
            // Test driver: submit a message through the extension's panel send path.
            guard let ext = extensionClient else { return reply(.failure(AgentError("no_extension", "Extension not connected."))) }
            ext.send(["type": "debug_send", "text": p["text"] as? String ?? ""])
            reply(.success(["ok": true]))
        case "debug.probe":
            guard let ext = extensionClient else { return reply(.failure(AgentError("no_extension", "Extension not connected."))) }
            let pid = UUID().uuidString
            probeReplies[pid] = { r in reply(.success(r)) }
            ext.send(["type": "debug_probe", "id": pid, "tabId": p["tabId"] ?? NSNull()])
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                if let r = self?.probeReplies.removeValue(forKey: pid) { r(["error": "timeout"]) }
            }
        case "debug.settings":
            guard let ext = extensionClient else { return reply(.failure(AgentError("no_extension", "Extension not connected."))) }
            ext.send(["type": "debug_settings", "settings": p["settings"] ?? [:], "newConversation": p["newConversation"] as? Bool ?? false])
            reply(.success(["ok": true]))
        case "debug.toggle":
            extensionClient?.send(["type": "debug_toggle"])
            reply(.success(["ok": extensionClient != nil]))
        case "debug.state":
            reply(.success(["extensionConnected": extensionClient != nil, "tools": currentTools.count, "running": runs.keys.first as Any]))
        case "debug.tool":
            // Test driver: run a browser tool directly (no AI), e.g. to verify page state.
            guard let name = p["name"] as? String else { return reply(.failure(AgentError("bad_request", "Missing name."))) }
            let run = Run(conversationId: "debug-\(UUID().uuidString.prefix(8))", messageId: "debug", provider: "debug")
            run.finished = true
            executeTool(run: run, name: name, args: p["args"] as? JSONObject ?? [:], emitEvents: false) { out in
                self.queue.async { reply(.success(["isError": out.isError, "content": out.content])) }
            }
        default:
            reply(.failure(AgentError("unknown_method", "Unknown method \(method).")))
        }
    }

    func refreshProviders(refresh: Bool, completion: (([JSONObject]) -> Void)? = nil) {
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
            if changed { self.broadcast(["type": "providers", "providers": list]) }
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
        broadcast(["type": "providers", "providers": list])
        DispatchQueue.main.async { self.onStatusChange?() }
    }

    private func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    private func chatSend(_ p: JSONObject, reply: @escaping Reply) {
        guard runs.isEmpty else { return reply(.failure(AgentError("busy", "A task is already running. Stop it before sending a new message."))) }
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
            conv = store.create(provider: providerId, model: model, title: String(text.prefix(60)))
        }
        if let model { conv.model = model }
        let userId = (p["userMessageId"] as? String) ?? "u\(Int(Date().timeIntervalSince1970 * 1000))"
        conv.messages.append(UIMessage(id: userId, role: "user", blocks: [Block(type: "text", text: text)], createdAt: Date().timeIntervalSince1970 * 1000))
        conv.updatedAt = Date().timeIntervalSince1970 * 1000
        store.update(conv)
        reply(.success(["conversationId": conv.id, "title": conv.title]))
        broadcast(["type": "conversations", "conversations": store.list().map { $0.summaryJSON() }])

        // Bind the task to the tab the user was viewing when they sent it.
        if let ctx = p["context"] as? JSONObject, let tabId = ctx["tabId"] as? Int {
            extensionClient?.send(["type": "bind_tab", "conversationId": conv.id, "tabId": tabId, "windowId": ctx["windowId"] ?? NSNull()])
        }
        let run = Run(conversationId: conv.id, messageId: "m\(UUID().uuidString.prefix(12).lowercased())", provider: providerId)
        runs[conv.id] = run
        emit(run, ["kind": "message_start", "messageId": run.messageId])
        let fullText = Prompts.userMessage(text: text, context: p["context"] as? JSONObject)
        prov.startTurn(conversation: conv, userText: fullText, model: model, effort: p["effort"] as? String, sink: TurnSink(hub: self, run: run))
    }

    // MARK: runs & events

    func emit(_ run: Run, _ event: JSONObject) {
        guard !run.finished || event["kind"] as? String == "done" else { return }
        if var conv = store.get(run.conversationId) {
            conv.apply(event)
            store.update(conv, persist: event["kind"] as? String == "done" || event["kind"] as? String == "tool_end")
        }
        broadcast(["type": "event", "conversationId": run.conversationId, "event": event])
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
        guard currentTools.isEmpty || currentTools.contains(where: { $0["name"] as? String == name }) else {
            return completion(.error("Unknown tool \(name)."))
        }
        run.toolSeq += 1
        let toolId = "t\(run.toolSeq)"
        if emitEvents {
            emit(run, ["kind": "tool_start", "messageId": run.messageId, "toolId": toolId, "name": name, "summary": ToolSummary.describe(name, args)])
        }
        guard let ext = extensionClient else {
            let msg = "The Safari extension is not connected to the helper. Ask the user to open the Safari Agent panel in Safari."
            if emitEvents { emit(run, ["kind": "tool_end", "messageId": run.messageId, "toolId": toolId, "status": "error", "detail": "Extension not connected"]) }
            return completion(.error(msg))
        }
        let callId = UUID().uuidString
        run.pendingToolCalls.insert(callId)
        pendingTools[callId] = (callId, run, toolId, { [weak self] out in
            completion(out)
            _ = self
        })
        ext.send(["type": "tool_call", "callId": callId, "conversationId": run.conversationId, "name": name, "args": args])
        // Approval prompts can take up to 5 minutes.
        queue.asyncAfter(deadline: .now() + 6 * 60) { [weak self] in
            guard let self, let p = self.pendingTools[callId] else { return }
            self.pendingTools[callId] = nil
            if emitEvents { self.emit(run, ["kind": "tool_end", "messageId": run.messageId, "toolId": toolId, "status": "error", "detail": "Timed out"]) }
            p.completion(.error("The browser did not respond to this action in time."))
        }
        _ = emitEvents
        toolEmitFlags[callId] = emitEvents
    }

    private var toolEmitFlags: [String: Bool] = [:]
    private var probeReplies: [String: (Any) -> Void] = [:]

    private func toolResult(_ msg: JSONObject) {
        guard let callId = msg["callId"] as? String, let p = pendingTools[callId] else { return }
        pendingTools[callId] = nil
        p.run.pendingToolCalls.remove(callId)
        let emitEvents = toolEmitFlags.removeValue(forKey: callId) ?? true
        let r = msg["result"] as? JSONObject ?? [:]
        let content = (r["content"] as? [JSONObject]) ?? [["type": "text", "text": "(no result)"]]
        let isError = r["isError"] as? Bool ?? false
        let out = ToolOutcome(content: content, isError: isError)
        let summary = msg["summary"] as? String
        if emitEvents {
            let denied = isError && out.text.hasPrefix("The user denied")
            emit(p.run, ["kind": "tool_end", "messageId": p.run.messageId, "toolId": p.toolId, "status": denied ? "denied" : (isError ? "error" : "done"), "detail": summary ?? ""])
        }
        p.completion(out)
    }
}

enum ToolSummary {
    static func describe(_ name: String, _ a: JSONObject) -> String {
        func s(_ k: String) -> String { (a[k] as? String).map { String($0.prefix(80)) } ?? "" }
        switch name {
        case "tabs_list": return "Listing tabs"
        case "read_page": return "Reading page structure"
        case "get_page_text": return "Reading page text"
        case "find": return "Finding “\(s("query"))”"
        case "get_selection": return "Reading selection"
        case "click": return "Clicking"
        case "type_text": return "Typing “\(s("text"))”"
        case "form_input": return "Setting a form field"
        case "press_key": return "Pressing \(s("key"))"
        case "scroll": return "Scrolling \(s("direction"))"
        case "navigate": return "Opening \(s("url"))"
        case "open_tab": return "Opening new tab \(s("url"))"
        case "switch_tab": return "Switching tab"
        case "close_tab": return "Closing tab"
        case "screenshot": return "Taking screenshot"
        case "wait": return "Waiting"
        default: return name
        }
    }
}
