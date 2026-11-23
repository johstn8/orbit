import Foundation

/// Server-sent events parser for the Responses API stream.
struct SSEParser {
    private var dataLines: [String] = []
    /// Feed one line (without newline). Returns a complete event's data when a blank line ends it.
    mutating func feed(_ line: String) -> String? {
        if line.isEmpty {
            defer { dataLines.removeAll() }
            return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var v = String(line.dropFirst(5))
            if v.hasPrefix(" ") { v.removeFirst() }
            dataLines.append(v)
        }
        return nil
    }
    mutating func flush() -> String? {
        defer { dataLines.removeAll() }
        return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
    }
}

/// ChatGPT via Sign in with ChatGPT + the public Responses API (plan usage, no API key).
final class ChatGPTProvider: Provider {
    let id = "chatgpt"
    private weak var hub: Hub?
    private var creds: ChatGPTCredentials?
    private var models: [JSONObject] = []
    private var modelsAt = Date.distantPast
    private var signInTask: Task<Void, Never>?
    private let lock = NSLock()
    /// Whether to group tools in a namespace (per the SIWC docs) or send plain function tools.
    private var useNamespace = true
    static let namespace = "browser"

    private var credsLoaded = false

    init(hub: Hub) {
        self.hub = hub
        // Credentials are read lazily off the main thread: a keychain access
        // prompt must never block the helper from starting.
    }

    // MARK: status

    func status(refresh: Bool, completion: @escaping (JSONObject) -> Void) {
        Task {
            var s: JSONObject = ["id": "chatgpt", "name": "ChatGPT", "models": [] as [JSONObject]]
            self.ensureCredsLoading()
            if !self.credsAreLoaded {
                s["available"] = false; s["state"] = "checking"
                s["detail"] = "Waiting for Keychain access — if macOS asks, allow “Safari Agent” to read its ChatGPT sign-in."
                return completion(s)
            }
            guard self.currentCreds() != nil else {
                s["available"] = false; s["state"] = "signed_out"
                s["detail"] = "Not signed in. Use “Continue with ChatGPT” to connect your ChatGPT plan (no API key needed)."
                return completion(s)
            }
            do {
                let ms = try await self.listModels(force: refresh)
                let c = self.currentCreds()
                s["available"] = !ms.isEmpty
                s["state"] = ms.isEmpty ? "error" : "ready"
                s["models"] = ms
                s["defaultModel"] = ms.first?["id"]
                s["efforts"] = [["id": "low", "name": "Light"], ["id": "medium", "name": "Standard"], ["id": "high", "name": "Extended"]]
                s["defaultEffort"] = "low"
                s["account"] = c?.email
                CodexUsage.refresh(accountEmail: c?.email)
                s["detail"] = ms.isEmpty ? "Your ChatGPT account has no models available for plan usage." : "Signed in with ChatGPT."
            } catch let e as AgentError {
                s["available"] = false
                s["state"] = e.code == "invalid_grant" || e.code == "unauthorized" ? "signed_out" : "error"
                s["detail"] = e.message
                s["account"] = self.currentCreds()?.email
            } catch {
                s["available"] = false; s["state"] = "error"; s["detail"] = "Could not reach ChatGPT: \(error.localizedDescription)"
            }
            completion(s)
        }
    }

    private let keychainQueue = DispatchQueue(label: "dev.local.SafariAgent.keychain")
    private var credsLoading = false

    /// Start reading the stored sign-in on a dedicated queue (never on the shared
    /// concurrency pool: a pending Keychain dialog would block it).
    private func ensureCredsLoading() {
        lock.lock()
        if credsLoaded || credsLoading { lock.unlock(); return }
        credsLoading = true
        lock.unlock()
        keychainQueue.async {
            let c = CredentialStore.load()
            self.lock.lock()
            if !self.credsLoaded { self.creds = c; self.credsLoaded = true }
            self.credsLoading = false
            self.lock.unlock()
            if let hub = self.hub { hub.queue.async { hub.refreshProviders(refresh: false) } }
        }
    }

    private var credsAreLoaded: Bool { lock.lock(); defer { lock.unlock() }; return credsLoaded }

    /// Non-blocking: nil until the Keychain read has finished.
    private func currentCreds() -> ChatGPTCredentials? {
        ensureCredsLoading()
        lock.lock(); defer { lock.unlock() }
        return creds
    }

    /// Waits (off the concurrency pool) for the Keychain read, for paths that need credentials.
    private func loadedCreds() async -> ChatGPTCredentials? {
        ensureCredsLoading()
        if credsAreLoaded { return currentCreds() }
        return await withCheckedContinuation { (c: CheckedContinuation<ChatGPTCredentials?, Never>) in
            keychainQueue.async { c.resume(returning: self.currentCreds()) }   // runs after the load finished
        }
    }
    private func setCreds(_ c: ChatGPTCredentials?) {
        lock.lock(); creds = c; credsLoaded = true; lock.unlock()
        if let c { CredentialStore.save(c) } else { CredentialStore.clear() }
    }

    // MARK: sign in / out

    func signIn(completion: @escaping (Result<Void, AgentError>) -> Void) {
        signInTask?.cancel()
        signInTask = Task {
            do {
                let c = try await ChatGPTOAuth.signIn(previous: await self.loadedCreds())
                guard c.scopes.contains(SIWC.usageScope) else {
                    throw AgentError("plan_usage_not_granted", "ChatGPT plan usage permission was not granted. Sign in again and allow Safari Agent to use your ChatGPT plan.")
                }
                self.setCreds(c)
                self.modelsAt = .distantPast
                Log.chatgpt.info("ChatGPT sign-in completed")
                completion(.success(()))
            } catch let e as AgentError {
                completion(.failure(e))
            } catch {
                completion(.failure(AgentError("signin_failed", "ChatGPT sign-in failed: \(error.localizedDescription)")))
            }
        }
    }

    func signOut(completion: @escaping () -> Void) {
        let c = currentCreds()
        setCreds(nil)
        models = []
        Task {
            if let c { await ChatGPTOAuth.revoke(c) }
            completion()
        }
    }

    // MARK: tokens

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let c = await loadedCreds() else { throw AgentError("unauthorized", "Not signed in to ChatGPT.") }
        if !forceRefresh && c.expiresAt - 90 > Date().timeIntervalSince1970 { return c.accessToken }
        do {
            let n = try await ChatGPTOAuth.refresh(c)
            setCreds(n)
            return n.accessToken
        } catch let e as AgentError where e.code == "invalid_grant" || e.code == "account_mismatch" {
            setCreds(nil)
            throw AgentError("unauthorized", "Your ChatGPT sign-in expired. Sign in again from Settings.")
        }
    }

    private func authorizedRequest(_ url: URL, method: String = "GET", body: Data? = nil, stream: Bool = false, retry: Bool = true) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let token = try await accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.timeoutInterval = 180
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AgentError("network_error", "Could not reach ChatGPT.") }
        noteLimits(http)
        if http.statusCode == 401 && retry {
            _ = try await accessToken(forceRefresh: true)
            return try await authorizedRequest(url, method: method, body: body, stream: stream, retry: false)
        }
        return (bytes, http)
    }

    /// Header names of the last response and the values of its rate-limit headers (for
    /// diagnostics; never the authorization or cookies).
    private(set) var lastHeaders: [String: JSONObject] = [:]

    /// Plan usage limits from the response headers (no extra request).
    private func noteLimits(_ http: HTTPURLResponse) {
        var h: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String { h[k.lowercased()] = "\(v)" }
        }
        // Opaque state tokens (x-codex-turn-state) are left out.
        let limitLike = h.filter { k, _ in (k.contains("ratelimit") || k.contains("rate-limit") || k.contains("codex") || k.contains("usage") || k.contains("limit")) && !k.contains("state") }
        lastHeaders[http.url?.path ?? ""] = ["names": h.keys.sorted(), "limits": limitLike, "status": http.statusCode]
        UsageStore.shared.update("chatgpt", UsageStore.fromHeaders(h))
    }

    private static func readAll(_ bytes: URLSession.AsyncBytes, limit: Int = 4_000_000) async throws -> Data {
        var d = Data()
        for try await b in bytes { d.append(b); if d.count > limit { break } }
        return d
    }

    // MARK: models

    func listModels(force: Bool) async throws -> [JSONObject] {
        if !force, !models.isEmpty, Date().timeIntervalSince(modelsAt) < 600 { return models }
        let (bytes, http) = try await authorizedRequest(URL(string: "\(SIWC.resource)/models")!)
        let data = try await Self.readAll(bytes)
        guard http.statusCode == 200 else { throw Self.apiError(JSON.parse(data), status: http.statusCode) }
        guard let arr = JSON.parse(data)?["models"] as? [JSONObject] else {
            throw AgentError("invalid_model_catalog", "ChatGPT returned an unexpected model catalog.")
        }
        let list: [JSONObject] = arr.compactMap { m in
            guard m["visibility"] as? String == "list", let slug = m["slug"] as? String, !slug.isEmpty else { return nil }
            return ["id": slug, "name": (m["display_name"] as? String) ?? slug]
        }
        models = list
        modelsAt = Date()
        return list
    }

    static func apiError(_ body: JSONObject?, status: Int) -> AgentError {
        let err = body?["error"] as? JSONObject
        let code = (err?["code"] as? String) ?? (body?["error"] as? String) ?? (err?["type"] as? String) ?? "http_\(status)"
        let message = (err?["message"] as? String) ?? ""
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return AgentError(code, "You've reached your ChatGPT plan's usage limit for apps. Try again later or check usage in ChatGPT settings.")
        case "subscription_sharing_usage_unavailable":
            return AgentError(code, "ChatGPT plan usage isn't available for this account right now (requires an eligible Plus/Pro plan).")
        default: break
        }
        if status == 401 { return AgentError("unauthorized", "Your ChatGPT sign-in is no longer valid. Sign in again from Settings.") }
        if status == 403 { return AgentError("forbidden", "ChatGPT refused the request\(message.isEmpty ? "" : ": \(message)")") }
        if status == 429 { return AgentError("rate_limited", "ChatGPT rate limit reached\(message.isEmpty ? "" : ": \(message)")") }
        return AgentError(code, "ChatGPT error (\(status))\(message.isEmpty ? "" : ": \(message)")")
    }

    // MARK: turns

    private var running: [String: Task<Void, Never>] = [:]

    func forget(conversationId: String) {
        running[conversationId]?.cancel()
        running[conversationId] = nil
    }

    func startTurn(conversation: Conversation, userText: String, attachments: [Attachment], model: String?, effort: String?, sink: TurnSink) {
        guard let hub else { return }
        let convId = conversation.id
        var items = hub.store.loadItems(convId)
        items.append(["role": "user", "content": Attachment.chatGPTParts(attachments) + [["type": "input_text", "text": userText]]])
        let modelId = model ?? conversation.model ?? models.first?["id"] as? String
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let modelId else { throw AgentError("no_model", "No ChatGPT model is available.") }
                try await self.agentLoop(items: &items, model: modelId, effort: effort, sink: sink)
                hub.store.saveItems(convId, Self.compact(items))
                sink.finish(cancelled: Task.isCancelled || sink.isCancelled)
                CodexUsage.refresh(accountEmail: self.currentCreds()?.email, force: true)
            } catch {
                // Keep history consistent even on failure/cancel.
                hub.store.saveItems(convId, Self.compact(Self.closeDanglingCalls(items)))
                if Task.isCancelled || sink.isCancelled || (error as? URLError)?.code == .cancelled {
                    sink.finish(cancelled: true)
                } else if let e = error as? AgentError {
                    sink.finish(error: e)
                } else {
                    sink.finish(error: AgentError("network_error", "Could not reach ChatGPT: \(error.localizedDescription)"))
                }
            }
            hub.queue.async { self.running[convId] = nil }
        }
        running[convId] = task
        sink.run.cancelHandler = { task.cancel() }
    }

    private func toolsPayload(_ conversationId: String) -> [JSONObject] {
        let fns: [JSONObject] = (hub?.toolCatalog(conversationId: conversationId) ?? []).map { t in
            ["type": "function", "name": t["name"] ?? "", "description": t["description"] ?? "", "parameters": t["input_schema"] ?? ["type": "object"], "strict": false]
        }
        if useNamespace {
            return [["type": "namespace", "name": Self.namespace, "description": "Read and operate the user's Safari browser tabs (and, when allowed, local files).", "tools": fns]]
        }
        return fns
    }

    private func agentLoop(items: inout [JSONObject], model: String, effort: String?, sink: TurnSink) async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            let outputs = try await streamOnce(items: items, model: model, effort: effort, sink: sink)
            // Items are not persisted server-side (store=false), so drop server ids except
            // on reasoning items, which carry encrypted content.
            let cleaned = outputs.map { o -> JSONObject in
                var o = o
                if o["type"] as? String != "reasoning" { o["id"] = nil }
                o["status"] = nil
                return o
            }
            items.append(contentsOf: cleaned)
            let calls = cleaned.filter { $0["type"] as? String == "function_call" }
            if calls.isEmpty { return }
            for call in calls {
                try Task.checkCancellation()
                let callId = call["call_id"] as? String ?? ""
                var name = call["name"] as? String ?? ""
                if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
                let argStr = call["arguments"] as? String ?? "{}"
                let args = JSON.parse(argStr) ?? [:]
                let out = await withCheckedContinuation { (c: CheckedContinuation<ToolOutcome, Never>) in
                    sink.callTool(name: name, args: args) { c.resume(returning: $0) }
                }
                items.append(["type": "function_call_output", "call_id": callId, "output": Self.outputPayload(out)])
            }
        }
        throw AgentError("max_steps", "The task took too many steps and was stopped.")
    }

    static func outputPayload(_ out: ToolOutcome) -> Any {
        let hasImage = out.content.contains { $0["type"] as? String == "image" }
        if !hasImage { return (out.isError ? "Error: " : "") + out.text }
        return out.content.map { c -> JSONObject in
            if c["type"] as? String == "image" {
                return ["type": "input_image", "image_url": "data:\(c["mediaType"] as? String ?? "image/jpeg");base64,\(c["data"] as? String ?? "")"]
            }
            return ["type": "input_text", "text": c["text"] as? String ?? ""]
        }
    }

    /// Make the history safe to persist and to resend: drop screenshots from old
    /// tool outputs and cap the length.
    static func compact(_ items: [JSONObject]) -> [JSONObject] {
        // Attached files are resent with the last 3 user messages only; older ones become a note.
        let userIdx = items.indices.filter { items[$0]["role"] as? String == "user" }
        let keepFrom = userIdx.count > 3 ? userIdx[userIdx.count - 3] : 0
        var out = items.enumerated().map { (n, item) -> JSONObject in
            if n < keepFrom, item["role"] as? String == "user", let parts = item["content"] as? [JSONObject],
               parts.contains(where: { ["input_image", "input_file"].contains($0["type"] as? String ?? "") }) {
                var i = item
                i["content"] = parts.map { p -> JSONObject in
                    switch p["type"] as? String {
                    case "input_image": return ["type": "input_text", "text": "[attached image omitted from history]"]
                    case "input_file": return ["type": "input_text", "text": "[attached file “\(p["filename"] as? String ?? "file")” omitted from history]"]
                    default: return p
                    }
                }
                return i
            }
            guard item["type"] as? String == "function_call_output", let arr = item["output"] as? [JSONObject] else { return item }
            var i = item
            i["output"] = arr.compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : "[screenshot omitted from history]" }.joined(separator: "\n")
            return i
        }
        if out.count > 300 {
            out = Array(out.suffix(300))
            // Don't start with an orphaned tool output.
            while let f = out.first, ["function_call_output", "reasoning"].contains(f["type"] as? String ?? "") { out.removeFirst() }
        }
        return out
    }

    /// Every function_call must be followed by an output; add one for calls interrupted by cancel/errors.
    static func closeDanglingCalls(_ items: [JSONObject]) -> [JSONObject] {
        var answered = Set(items.compactMap { $0["type"] as? String == "function_call_output" ? $0["call_id"] as? String : nil })
        var out: [JSONObject] = []
        for i in items {
            out.append(i)
            if i["type"] as? String == "function_call", let cid = i["call_id"] as? String, !answered.contains(cid) {
                out.append(["type": "function_call_output", "call_id": cid, "output": "Error: the action was interrupted."])
                answered.insert(cid)
            }
        }
        return out
    }

    private var supportsReasoningEffort = true

    private func streamOnce(items: [JSONObject], model: String, effort: String?, sink: TurnSink, attempt: Int = 0) async throws -> [JSONObject] {
        var body: JSONObject = [
            "model": model,
            "instructions": Prompts.system,
            "input": items,
            "tools": toolsPayload(sink.run.conversationId),
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
            "include": ["reasoning.encrypted_content"],
        ]
        if let effort, supportsReasoningEffort, ["low", "medium", "high"].contains(effort) { body["reasoning"] = ["effort": effort] }
        let (bytes, http) = try await authorizedRequest(URL(string: "\(SIWC.resource)/responses")!, method: "POST", body: JSON.data(body), stream: true)
        if http.statusCode != 200 {
            let data = try await Self.readAll(bytes)
            let obj = JSON.parse(data)
            let msg = ((obj?["error"] as? JSONObject)?["message"] as? String ?? "").lowercased()
            Log.chatgpt.notice("responses HTTP \(http.statusCode, privacy: .public) code=\(((obj?["error"] as? JSONObject)?["code"] as? String) ?? "-", privacy: .public)")
            if http.statusCode == 400 && attempt == 0 && useNamespace && (msg.contains("namespace") || msg.contains("tools")) {
                useNamespace = false
                return try await streamOnce(items: items, model: model, effort: effort, sink: sink, attempt: 1)
            }
            if http.statusCode == 400 && attempt < 2 && supportsReasoningEffort && body["reasoning"] != nil && (msg.contains("reasoning") || msg.contains("effort")) {
                supportsReasoningEffort = false
                return try await streamOnce(items: items, model: model, effort: nil, sink: sink, attempt: attempt + 1)
            }
            if http.statusCode == 400 && attempt < 2 && msg.contains("not found") && items.contains(where: { $0["type"] as? String == "reasoning" }) {
                return try await streamOnce(items: items.filter { $0["type"] as? String != "reasoning" }, model: model, effort: effort, sink: sink, attempt: attempt + 1)
            }
            throw Self.apiError(obj, status: http.statusCode)
        }
        var parser = SSEParser()
        var outputs: [JSONObject] = []
        var completedOutput: [JSONObject]?
        var sawText = false
        func handle(_ data: String) throws -> Bool {
            guard let ev = JSON.parse(data) else { return false }
            // Plan limits, when the stream reports them (Codex-style `rate_limits`).
            if let rl = (ev["rate_limits"] as? JSONObject) ?? ((ev["response"] as? JSONObject)?["rate_limits"] as? JSONObject) {
                UsageStore.shared.update("chatgpt", UsageStore.fromRateLimits(rl))
            }
            switch ev["type"] as? String {
            case "response.output_text.delta":
                if let d = ev["delta"] as? String { sawText = true; sink.text(d) }
            case "response.output_item.added":
                if let item = ev["item"] as? JSONObject {
                    switch item["type"] as? String {
                    case "reasoning": sink.status("Thinking…")
                    case "function_call": sink.status("Using the browser…")
                    case "message": if sawText { sink.text("\n\n") }; sink.status("Writing…")
                    default: break
                    }
                }
            case "response.output_item.done":
                if let item = ev["item"] as? JSONObject { outputs.append(item) }
            case "response.completed":
                completedOutput = ((ev["response"] as? JSONObject)?["output"] as? [JSONObject])
                return true
            case "response.failed", "error":
                let detail = ev["type"] as? String == "error" ? ev : (ev["response"] as? JSONObject)
                throw Self.apiError(detail.map { d in d["error"] != nil ? d : ["error": d] }, status: 200)
            case "response.incomplete":
                throw AgentError("response_incomplete", "ChatGPT stopped before completing the response.")
            default: break
            }
            return false
        }
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            // AsyncLineSequence drops empty lines, so treat each "data:" line as a full event.
            if line.hasPrefix("data:") {
                _ = parser.feed(line)
                if let d = parser.flush(), try handle(d) { completed = true; break }
            }
        }
        if !completed {
            if let d = parser.flush(), try handle(d) { completed = true }
        }
        try Task.checkCancellation()
        guard completed else { throw AgentError("stream_interrupted", "The ChatGPT response ended before completion.") }
        if let c = completedOutput, !c.isEmpty { return c }
        return outputs
    }
}


