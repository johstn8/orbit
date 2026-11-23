import Foundation

/// ChatGPT's plan limits, read from the user's own, unmodified Codex app.
///
/// Orbit's ChatGPT replies don't carry the limits, and ChatGPT's usage service doesn't
/// accept Orbit's sign-in. The Codex app asks that service with its own sign-in when
/// queried over its local app server (`codex app-server`, JSON-RPC over stdio:
/// `account/rateLimits/read`). That is a read and uses no quota. Orbit never reads or
/// copies Codex's credentials; it only starts the process and reads the reply.
/// The limits are only used when Codex is signed in to the same ChatGPT account as Orbit.
enum CodexUsage {
    private static var cachedPath: String?
    private static let lock = NSLock()
    private static var lastRun = Date.distantPast
    private static var running = false

    static func locate() -> String? {
        if let p = cachedPath, FileManager.default.isExecutableFile(atPath: p) { return p }
        let home = Paths.home.path
        for c in ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.npm-global/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        where FileManager.default.isExecutableFile(atPath: c) {
            cachedPath = c
            return c
        }
        return nil
    }

    /// Refresh the ChatGPT limits (at most once a minute unless `force`).
    static func refresh(accountEmail: String?, force: Bool = false) {
        guard let email = accountEmail?.lowercased(), !email.isEmpty, let exe = locate() else { return }
        lock.lock()
        if running || (!force && Date().timeIntervalSince(lastRun) < 60) { lock.unlock(); return }
        running = true
        lastRun = Date()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            defer { lock.lock(); running = false; lock.unlock() }
            guard let replies = query(exe, timeout: 15) else { return }
            let acct = ((replies[2] as? JSONObject)?["account"] as? JSONObject)?["email"] as? String
            guard acct?.lowercased() == email else {
                Log.chatgpt.info("Codex is signed in to another account; ChatGPT limits not shown")
                return
            }
            guard let rl = (replies[3] as? JSONObject)?["rateLimits"] as? JSONObject else { return }
            UsageStore.shared.update("chatgpt", windows(rl))
        }
    }

    /// `rateLimits` of `account/rateLimits/read` (camelCase, like Codex's own rollouts).
    static func windows(_ rl: JSONObject) -> [UsageStore.Window] {
        var out: [UsageStore.Window] = []
        for slot in ["primary", "secondary"] {
            guard let w = rl[slot] as? JSONObject, let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["windowDurationMins"] as? NSNumber)?.doubleValue
            let id = minutes.map { $0 <= 24 * 60 ? "five_hour" : "weekly" } ?? (slot == "primary" ? "five_hour" : "weekly")
            out.append(UsageStore.Window(id: id, used: used, resetsAt: (w["resetsAt"] as? NSNumber)?.doubleValue))
        }
        return out
    }

    /// Start `codex app-server`, ask for the account and the limits, and stop it again.
    private static func query(_ exe: String, timeout: TimeInterval) -> [Int: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["app-server"]
        p.environment = ClaudeCLI.cleanEnvironment()
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        defer { if p.isRunning { p.terminate() } }
        let msgs: [JSONObject] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "orbit", "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "account/read", "params": [:] as JSONObject],
            ["jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read"],
        ]
        for m in msgs { input.fileHandleForWriting.write(JSON.data(m) + Data("\n".utf8)) }

        var replies: [Int: Any] = [:]
        var buffer = Data()
        let done = DispatchSemaphore(value: 0)
        let q = DispatchQueue(label: "dev.local.SafariAgent.codexusage")
        output.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            q.sync {
                if chunk.isEmpty { done.signal(); return }
                buffer.append(chunk)
                if buffer.count > 2_000_000 { done.signal(); return }
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject, let id = (obj["id"] as? NSNumber)?.intValue else { continue }
                    replies[id] = obj["result"] ?? NSNull()
                    if replies[2] != nil && replies[3] != nil { done.signal() }
                }
            }
        }
        _ = done.wait(timeout: .now() + timeout)
        output.fileHandleForReading.readabilityHandler = nil
        return q.sync { replies }
    }
}
