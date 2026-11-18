import Foundation
import AppKit

/// Locates and queries the user's locally installed, unmodified Claude Code CLI.
/// Authentication is the CLI's own (claude.ai subscription login stored in the
/// macOS keychain by Claude Code). We never read or copy those credentials.
enum ClaudeCLI {
    static var cachedPath: String?

    static func cleanEnvironment() -> [String: String] {
        let home = Paths.home.path
        var env: [String: String] = [
            "HOME": home,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "PATH": "\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            // Keep the CLI quiet and non-interactive.
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1",
        ]
        if let term = ProcessInfo.processInfo.environment["TERM"] { env["TERM"] = term }
        // Never pass API keys or another host's session through: the user's own
        // subscription login must be what authenticates.
        return env
    }

    static func locate() -> String? {
        if let p = cachedPath, FileManager.default.isExecutableFile(atPath: p) { return p }
        let home = Paths.home.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            cachedPath = c
            return c
        }
        // Fall back to the user's login shell PATH.
        if let out = run("/bin/zsh", ["-lc", "command -v claude"], timeout: 8, env: nil)?.stdout {
            let p = out.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if p.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: p) { cachedPath = p; return p }
        }
        return nil
    }

    struct RunResult { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval, env: [String: String]? = cleanEnvironment(), cwd: URL? = nil) -> RunResult? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); usleep(200_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        _ = g.wait(timeout: .now() + 2)
        return RunResult(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self))
    }

    struct AuthStatus {
        var installed: Bool
        var loggedIn: Bool
        var method: String?
        var email: String?
        var version: String?
        var error: String?
    }

    static func authStatus() -> AuthStatus {
        guard let exe = locate() else {
            return AuthStatus(installed: false, loggedIn: false, error: "Claude Code is not installed. Install it from https://code.claude.com, then sign in.")
        }
        let version = run(exe, ["--version"], timeout: 15)?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = run(exe, ["auth", "status"], timeout: 20), let obj = JSON.parse(r.stdout) else {
            return AuthStatus(installed: true, loggedIn: false, version: version, error: "Could not read Claude Code's sign-in status.")
        }
        let logged = obj["loggedIn"] as? Bool ?? false
        let email = (obj["email"] as? String) ?? (obj["account"] as? JSONObject)?["email"] as? String
        return AuthStatus(installed: true, loggedIn: logged, method: obj["authMethod"] as? String, email: email, version: version)
    }

    /// Opens Terminal running `claude auth login` (the CLI's normal browser-based sign-in).
    static func openLoginInTerminal() {
        guard let exe = locate() else {
            NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/setup")!)
            return
        }
        let script = Paths.run.appendingPathComponent("claude-login.command")
        let body = """
        #!/bin/zsh
        echo "Signing in to Claude Code with your Claude subscription…"
        env -i HOME="$HOME" USER="$USER" TERM="$TERM" PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" '\(exe.replacingOccurrences(of: "'", with: "'\\''"))' auth login
        echo
        echo "You can close this window and return to Safari."
        """
        try? Paths.writePrivate(Data(body.utf8), to: script)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
    }
}

/// One long-lived `claude -p` process per conversation, speaking stream-json.
final class ClaudeSession {
    let conversationId: String
    let model: String?
    let effort: String?
    /// Which tools the MCP bridge offered when the session started.
    var toolset = ""
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private let queue = DispatchQueue(label: "dev.local.SafariAgent.claude-session")
    private var sink: TurnSink?
    private var interruptRequested = false
    private var sawText = false
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?
    var onExit: (() -> Void)?
    var isAlive: Bool { process?.isRunning ?? false }

    init(conversationId: String, model: String?, effort: String?) {
        self.conversationId = conversationId
        self.model = model
        self.effort = effort
    }

    func start(exe: String, resume: String?, mcpConfigPath: URL) throws {
        Paths.ensure(Paths.claudeWorkdir)
        var args = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--strict-mcp-config", "--mcp-config", mcpConfigPath.path,
            "--tools", "",
            "--allowedTools", "mcp__safari",
            "--permission-prompts", "none",
            "--setting-sources", "",
            "--system-prompt", Prompts.system,
        ]
        if let model, !model.isEmpty, model != "default" { args += ["--model", model] }
        if let effort, ["low", "medium", "high", "xhigh", "max"].contains(effort) { args += ["--effort", effort] }
        if let resume { args += ["--resume", resume] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ClaudeCLI.cleanEnvironment()
        p.currentDirectoryURL = Paths.claudeWorkdir
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.consume(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            self?.queue.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + String(decoding: d, as: UTF8.self)).suffix(2000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.exited(status: proc.terminationStatus) }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        Log.claude.info("claude session started (resume: \(resume != nil, privacy: .public))")
        startIdleTimer()
    }

    private func startIdleTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Free resources after 15 idle minutes; the next turn resumes the session.
            if self.sink == nil, Date().timeIntervalSince(self.lastActivity) > 15 * 60 { self.terminate() }
        }
        t.resume()
        idleTimer = t
    }

    func send(text: String, sink: TurnSink) {
        queue.async {
            self.sink = sink
            self.interruptRequested = false
            self.sawText = false
            self.lastActivity = Date()
            let msg: JSONObject = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
            self.write(msg)
        }
    }

    func interrupt() {
        queue.async {
            guard self.sink != nil else { return }
            self.interruptRequested = true
            self.write(["type": "control_request", "request_id": "int-\(UUID().uuidString.prefix(8))", "request": ["subtype": "interrupt"]])
            // If the CLI doesn't wind down promptly, stop the process; the session resumes next time.
            self.queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.interruptRequested, self.sink != nil else { return }
                self.terminate()
            }
        }
    }

    private func write(_ obj: JSONObject) {
        guard let stdin else { return }
        var d = JSON.data(obj)
        d.append(0x0A)
        do { try stdin.write(contentsOf: d) } catch { Log.claude.error("write to claude failed") }
    }

    func terminate() {
        guard let p = process, p.isRunning else { return }
        try? stdin?.close()
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(pid, SIGKILL) } }
    }

    private func consume(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = JSON.parse(line) { handle(obj) }
        }
    }

    private func handle(_ m: JSONObject) {
        lastActivity = Date()
        let type = m["type"] as? String ?? ""
        switch type {
        case "system":
            if m["subtype"] as? String == "init", let sid = m["session_id"] as? String { sink?.setClaudeSession(sid) }
            if m["subtype"] as? String == "status", let s = m["status"] as? String, s == "requesting" { sink?.status("Thinking…") }
        case "stream_event":
            guard let ev = m["event"] as? JSONObject else { return }
            let et = ev["type"] as? String
            if et == "content_block_delta", let delta = ev["delta"] as? JSONObject, delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                sawText = true
                sink?.text(t)
            } else if et == "content_block_start", let cb = ev["content_block"] as? JSONObject {
                switch cb["type"] as? String {
                case "thinking": sink?.status("Thinking…")
                case "tool_use": sink?.status("Using the browser…")
                case "text":
                    // Separate text from a previous step so Markdown paragraphs don't run together.
                    if sawText { sink?.text("\n\n") }
                    sink?.status("Writing…")
                default: break
                }
            }
        case "result":
            guard let s = sink else { return }
            sink = nil
            let cancelled = interruptRequested
            interruptRequested = false
            if let sid = m["session_id"] as? String { s.setClaudeSession(sid) }
            let isError = (m["is_error"] as? Bool ?? false) || ((m["subtype"] as? String).map { $0 != "success" } ?? false)
            if isError && !cancelled {
                s.finish(error: ClaudeProvider.mapError(result: m["result"] as? String, subtype: m["subtype"] as? String, stderr: stderrTail))
            } else {
                if !sawText, !cancelled, let r = m["result"] as? String, !r.isEmpty { s.text(r) }
                s.finish(cancelled: cancelled)
            }
        default:
            break
        }
    }

    private func exited(status: Int32) {
        idleTimer?.cancel()
        idleTimer = nil
        process = nil
        stdin = nil
        if let s = sink {
            sink = nil
            if interruptRequested { s.finish(cancelled: true) }
            else { s.finish(error: ClaudeProvider.mapError(result: nil, subtype: "exit \(status)", stderr: stderrTail)) }
        }
        interruptRequested = false
        Log.claude.info("claude session exited with status \(status, privacy: .public)")
        onExit?()
    }
}

final class ClaudeProvider: Provider {
    let id = "claude"
    private weak var hub: Hub?
    private var sessions: [String: ClaudeSession] = [:]
    private var cachedStatus: JSONObject?
    private var cachedAt = Date.distantPast
    private let statusQueue = DispatchQueue(label: "dev.local.SafariAgent.claude-status")

    static let models: [JSONObject] = [
        ["id": "claude-opus-5-5", "name": "Opus 5.5", "description": "For complex work and everyday tasks"],
        ["id": "claude-fable-5-2", "name": "Fable 5.2", "description": "For your hardest challenges"],
        ["id": "claude-sonnet-5-5", "name": "Sonnet 5.5", "description": "Most efficient for simpler tasks"],
        ["id": "claude-haiku-5-5", "name": "Haiku 5.5", "description": "Fastest for quick answers"],
    ]
    static let efforts: [JSONObject] = [
        ["id": "low", "name": "Low"], ["id": "medium", "name": "Medium"], ["id": "high", "name": "High"], ["id": "max", "name": "Max"],
    ]

    init(hub: Hub) { self.hub = hub }

    func status(refresh: Bool, completion: @escaping (JSONObject) -> Void) {
        if !refresh, let c = cachedStatus, Date().timeIntervalSince(cachedAt) < 60 { return completion(c) }
        statusQueue.async {
            let a = ClaudeCLI.authStatus()
            var s: JSONObject = ["id": "claude", "name": "Claude", "models": ClaudeProvider.models, "defaultModel": "claude-opus-5-5", "efforts": ClaudeProvider.efforts, "defaultEffort": "medium"]
            if !a.installed {
                s["available"] = false; s["state"] = "not_installed"; s["detail"] = a.error
            } else if let err = a.error {
                s["available"] = false; s["state"] = "error"; s["detail"] = err
            } else if !a.loggedIn {
                s["available"] = false; s["state"] = "signed_out"
                s["detail"] = "Claude Code is installed but not signed in. Click “Sign in with Claude…” (runs `claude auth login`)."
            } else if let m = a.method, m != "claude.ai" {
                // Only a Claude subscription login is used; API-key / Console billing is not.
                s["available"] = false; s["state"] = "signed_out"
                s["detail"] = "Claude Code is signed in with “\(m)”, which is billed separately. Sign in with your Claude.ai subscription instead (`claude auth login`)."
            } else {
                s["available"] = true; s["state"] = "ready"
                s["detail"] = "Signed in to Claude Code with your Claude subscription\(a.version.map { " (\($0))" } ?? "")."
                if let e = a.email { s["account"] = e }
            }
            self.cachedStatus = s
            self.cachedAt = Date()
            completion(s)
        }
    }

    func startTurn(conversation: Conversation, userText: String, model: String?, effort: String?, sink: TurnSink) {
        guard let hub else { return }
        guard let exe = ClaudeCLI.locate() else {
            return sink.finish(error: AgentError("not_installed", "Claude Code is not installed."))
        }
        let convId = conversation.id
        var session = sessions[convId]
        let wantModel = model ?? conversation.model
        let toolset = hub.toolsetKey
        if let s = session, (!s.isAlive || s.model != wantModel || s.effort != effort || s.toolset != toolset) {
            s.terminate()
            session = nil
        }
        if session == nil {
            let s = ClaudeSession(conversationId: convId, model: wantModel, effort: effort)
            s.toolset = toolset
            s.onExit = { [weak self, weak s] in
                hub.queue.async { if let s, self?.sessions[convId] === s { self?.sessions[convId] = nil } }
            }
            let token = hub.issueBridgeToken(conversationId: convId)
            let cfgURL = Paths.run.appendingPathComponent("mcp-\(convId).json")
            let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let cfg: JSONObject = ["mcpServers": ["safari": [
                "type": "stdio",
                "command": exePath,
                "args": ["--mcp-bridge"],
                "env": ["SAFARI_AGENT_PORT": String(hub.port), "SAFARI_AGENT_BRIDGE_TOKEN": token],
            ]]]
            do {
                try Paths.writePrivate(JSON.data(cfg), to: cfgURL)
                try s.start(exe: exe, resume: conversation.claudeSessionId, mcpConfigPath: cfgURL)
            } catch {
                return sink.finish(error: AgentError("launch_failed", "Could not start Claude Code: \(error.localizedDescription)"))
            }
            sessions[convId] = s
            session = s
        }
        sink.run.cancelHandler = { [weak session] in session?.interrupt() }
        session!.send(text: userText, sink: sink)
    }

    func forget(conversationId: String) {
        sessions[conversationId]?.terminate()
        sessions[conversationId] = nil
    }

    func shutdown() {
        for s in sessions.values { s.terminate() }
        sessions.removeAll()
    }

    static func mapError(result: String?, subtype: String?, stderr: String) -> AgentError {
        let text = [result ?? "", stderr].joined(separator: "\n")
        let lower = text.lowercased()
        if lower.contains("/login") || lower.contains("not logged in") || lower.contains("oauth token has expired") || lower.contains("authentication_error") || lower.contains("invalid api key") {
            return AgentError("auth", "Claude Code is not signed in or its session expired. Open Settings → “Sign in with Claude…”, finish the sign-in, then try again.")
        }
        if lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("limit reached") {
            return AgentError("rate_limited", "Your Claude usage limit has been reached. \(result ?? "")".trimmingCharacters(in: .whitespaces))
        }
        if let subtype, subtype.hasPrefix("error_max_turns") {
            return AgentError("max_turns", "Claude stopped because the task took too many steps.")
        }
        if let r = result, !r.isEmpty { return AgentError("claude_error", "Claude Code error: \(r.prefix(400))") }
        let tail = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return AgentError("claude_error", "Claude Code stopped unexpectedly (\(subtype ?? "unknown"))\(tail.isEmpty ? "" : ": \(tail.prefix(300))").")
    }
}
