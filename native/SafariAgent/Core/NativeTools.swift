import Foundation
import AppKit

/// Local computer tools (files and, optionally, shell commands) executed by the
/// helper itself. Every call is checked here, independent of the model:
/// - the user's computer-access tier (none / chosen folders / full),
/// - a path policy (allowed roots, symlink resolution, credential stores denied),
/// - approvals shown in the chat's own Safari panel.
/// Conversations that have read web content always ask before changing files,
/// so instructions hidden in a website can't silently modify the computer.
final class NativeTools {
    static let shared = NativeTools()

    struct Context {
        var conversationId: String
        var profileId: String
        var approvalMode: String
        var sawWebContent: Bool
    }

    static let readTools: Set<String> = ["fs_list", "fs_read", "fs_search"]
    static let writeTools: Set<String> = ["fs_write", "fs_edit", "fs_move", "fs_trash"]
    static let commandTool = "run_command"

    static func handles(_ name: String) -> Bool { readTools.contains(name) || writeTools.contains(name) || name == commandTool }
    static func readsLocalData(_ name: String) -> Bool { readTools.contains(name) || name == commandTool }

    private let work = DispatchQueue(label: "dev.local.SafariAgent.nativetools", attributes: .concurrent)
    private var processes: [String: Process] = [:]
    private let lock = NSLock()

    // MARK: catalog

    static func catalog(_ a: AgentSettings) -> [JSONObject] {
        guard a.computerAccess != "none" else { return [] }
        let where_ = a.computerAccess == "folders" ? "inside the folders the user allowed" : "in the user's home folder"
        func tool(_ name: String, _ desc: String, _ props: JSONObject, _ required: [String]) -> JSONObject {
            ["name": name, "description": desc, "input_schema": ["type": "object", "properties": props, "required": required]]
        }
        let path: JSONObject = ["type": "string", "description": "Absolute path, ~/path, or a path relative to the first allowed folder."]
        var t: [JSONObject] = [
            tool("fs_list", "List a folder on the user's Mac (\(where_)). Returns names, kinds and sizes.", ["path": path, "depth": ["type": "integer", "description": "1–3, default 1"]], ["path"]),
            tool("fs_read", "Read a text file on the user's Mac (\(where_)).", ["path": path, "offset_line": ["type": "integer"], "max_lines": ["type": "integer"]], ["path"]),
            tool("fs_search", "Find files by name pattern and/or containing text (\(where_)).", ["path": path, "name_glob": ["type": "string", "description": "e.g. *.md"], "contains": ["type": "string"], "max_results": ["type": "integer"]], ["path"]),
            tool("fs_write", "Create a text file, or overwrite one when overwrite=true. The user may be asked to approve.", ["path": path, "content": ["type": "string"], "overwrite": ["type": "boolean"]], ["path", "content"]),
            tool("fs_edit", "Edit a text file by replacing an exact text passage. The user may be asked to approve.", ["path": path, "old_text": ["type": "string"], "new_text": ["type": "string"], "replace_all": ["type": "boolean"]], ["path", "old_text", "new_text"]),
            tool("fs_move", "Move or rename a file or folder. The user may be asked to approve.", ["from": path, "to": path], ["from", "to"]),
            tool("fs_trash", "Move a file or folder to the Trash (recoverable). Always asks the user.", ["path": path], ["path"]),
        ]
        if a.computerAccess == "full" && a.allowCommands {
            t.append(tool("run_command", "Run a shell command (zsh) on the user's Mac. Every command is shown to the user for approval before it runs. Output is truncated.",
                          ["command": ["type": "string"], "cwd": path, "timeout_seconds": ["type": "integer", "description": "default 60, max 300"]], ["command"]))
        }
        return t
    }

    static func describe(_ name: String, _ a: JSONObject) -> String? {
        func s(_ k: String) -> String { PathPolicy.display((a[k] as? String) ?? "") }
        switch name {
        case "fs_list": return "Listing \(s("path"))"
        case "fs_read": return "Reading \(s("path"))"
        case "fs_search": return "Searching \(s("path"))"
        case "fs_write": return "Writing \(s("path"))"
        case "fs_edit": return "Editing \(s("path"))"
        case "fs_move": return "Moving \(s("from")) → \(s("to"))"
        case "fs_trash": return "Moving \(s("path")) to Trash"
        case "run_command": return "Running “\(String(((a["command"] as? String) ?? "").prefix(60)))”"
        default: return nil
        }
    }

    // MARK: execution

    func cancel(conversationId: String) {
        lock.lock(); let p = processes.removeValue(forKey: conversationId); lock.unlock()
        if let p, p.isRunning { kill(-p.processIdentifier, SIGTERM); p.terminate() }
    }

    func execute(name: String, args: JSONObject, context: Context, completion: @escaping (ToolOutcome, String?) -> Void) {
        let settings = SettingsStore.shared.current.agent
        guard settings.computerAccess != "none" else {
            return completion(.error("Computer access is turned off. Ask the user to allow it under Computer access in Orbit's settings or the panel."), "Computer access is off")
        }
        let policy = PathPolicy(access: settings.computerAccess, folders: settings.folders)
        if settings.computerAccess == "folders" && policy.roots.isEmpty {
            return completion(.error("No folders are allowed yet. Ask the user to choose folders under Computer access."), "No folders allowed")
        }
        if name == Self.commandTool && !(settings.computerAccess == "full" && settings.allowCommands) {
            return completion(.error("Running commands is not allowed. The user can enable it with full computer access."), "Commands not allowed")
        }
        work.async {
            do {
                let plan = try self.prepare(name: name, args: args, policy: policy)
                let needsApproval: Bool
                switch name {
                case _ where Self.readTools.contains(name): needsApproval = context.approvalMode == "always"
                case "fs_trash", Self.commandTool: needsApproval = true
                default: needsApproval = context.approvalMode != "never" || context.sawWebContent
                }
                let run = {
                    self.work.async {
                        do {
                            let text = try plan.perform(context.conversationId)
                            completion(.ok(text), plan.summary)
                        } catch {
                            completion(.error(self.message(error)), self.message(error))
                        }
                    }
                }
                guard needsApproval else { return run() }
                var reason = plan.reason
                if context.sawWebContent && Self.writeTools.contains(name) && context.approvalMode == "never" {
                    reason += " This chat has read website content, so Orbit asks before files change."
                }
                Hub.shared.queue.async {
                    Hub.shared.requestApproval(profileId: context.profileId, conversationId: context.conversationId, tool: name, summary: plan.approvalSummary, reason: reason) { ok in
                        if ok { run() }
                        else { completion(.error("The user denied this action (\(plan.summary)). Do not retry it; ask the user how to proceed."), "Denied") }
                    }
                }
            } catch {
                completion(.error(self.message(error)), self.message(error))
            }
        }
    }

    private func message(_ e: Error) -> String {
        if let e = e as? ToolFail { return e.message }
        return (e as NSError).localizedDescription
    }

    struct ToolFail: Error { let message: String; init(_ m: String) { message = m } }

    struct Plan {
        var summary: String
        var approvalSummary: String
        var reason: String
        var perform: (String) throws -> String
    }

    private func prepare(name: String, args: JSONObject, policy: PathPolicy) throws -> Plan {
        let fm = FileManager.default
        func str(_ k: String) -> String { (args[k] as? String) ?? "" }
        func int(_ k: String, _ d: Int) -> Int { (args[k] as? Int) ?? (args[k] as? Double).map { Int($0) } ?? d }
        switch name {
        case "fs_list":
            let url = try policy.resolve(str("path"), write: false)
            let depth = max(1, min(3, int("depth", 1)))
            return Plan(summary: "Listed \(PathPolicy.display(url.path))", approvalSummary: "List \(PathPolicy.display(url.path))", reason: "You asked to approve every action.") { _ in
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ToolFail("Not found: \(PathPolicy.display(url.path))") }
                guard isDir.boolValue else { throw ToolFail("Not a folder: \(PathPolicy.display(url.path))") }
                var lines: [String] = []
                func walk(_ u: URL, _ level: Int, _ prefix: String) {
                    guard lines.count < 500 else { return }
                    let items = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                    for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                        guard lines.count < 500 else { lines.append("… (truncated)"); return }
                        if policy.isDenied(item) { continue }
                        let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        if v?.isDirectory == true {
                            lines.append("\(prefix)\(item.lastPathComponent)/")
                            if level < depth { walk(item, level + 1, prefix + "  ") }
                        } else {
                            lines.append("\(prefix)\(item.lastPathComponent) (\(Self.size(v?.fileSize ?? 0)))")
                        }
                    }
                }
                walk(url, 1, "")
                return "Contents of \(url.path):\n" + (lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
            }
        case "fs_read":
            let url = try policy.resolve(str("path"), write: false)
            let offset = max(0, int("offset_line", 0))
            let maxLines = max(1, min(4000, int("max_lines", 2000)))
            return Plan(summary: "Read \(PathPolicy.display(url.path))", approvalSummary: "Read \(PathPolicy.display(url.path))", reason: "You asked to approve every action.") { _ in
                guard let data = fm.contents(atPath: url.path) else { throw ToolFail("Cannot read \(PathPolicy.display(url.path)) (missing, a folder, or no permission).") }
                if data.count > 5_000_000 { throw ToolFail("The file is too large to read (\(Self.size(data.count))).") }
                guard let text = String(data: data, encoding: .utf8) else { return "Binary file (\(Self.size(data.count))); it can't be shown as text." }
                let all = text.components(separatedBy: "\n")
                let slice = all.dropFirst(offset).prefix(maxLines)
                var out = slice.joined(separator: "\n")
                if out.count > 200_000 { out = String(out.prefix(200_000)) + "\n… (truncated)" }
                let more = offset + slice.count < all.count ? "\n… (\(all.count - offset - slice.count) more lines; use offset_line)" : ""
                return "<local_file path=\"\(url.path)\" lines=\"\(offset + 1)-\(offset + slice.count) of \(all.count)\">\n\(out)\(more)\n</local_file>"
            }
        case "fs_search":
            let url = try policy.resolve(str("path"), write: false)
            let glob = str("name_glob"), contains = str("contains")
            let maxResults = max(1, min(500, int("max_results", 100)))
            return Plan(summary: "Searched \(PathPolicy.display(url.path))", approvalSummary: "Search \(PathPolicy.display(url.path))", reason: "You asked to approve every action.") { _ in
                guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw ToolFail("Cannot search \(PathPolicy.display(url.path)).") }
                var hits: [String] = []
                var scanned = 0
                for case let f as URL in en {
                    if ["node_modules", ".git", "DerivedData", "build"].contains(f.lastPathComponent) { en.skipDescendants(); continue }
                    if policy.isDenied(f) { en.skipDescendants(); continue }
                    scanned += 1
                    if scanned > 50_000 || hits.count >= maxResults { break }
                    let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard v?.isRegularFile == true else { continue }
                    if !glob.isEmpty && fnmatch(glob, f.lastPathComponent, FNM_CASEFOLD) != 0 { continue }
                    if !contains.isEmpty {
                        guard (v?.fileSize ?? 0) < 2_000_000, let d = fm.contents(atPath: f.path), let t = String(data: d, encoding: .utf8) else { continue }
                        guard let r = t.range(of: contains, options: .caseInsensitive) else { continue }
                        let lineNo = t[..<r.lowerBound].filter { $0 == "\n" }.count + 1
                        let line = t[t.lineRange(for: r)].trimmingCharacters(in: .whitespacesAndNewlines)
                        hits.append("\(f.path):\(lineNo): \(line.prefix(160))")
                    } else {
                        hits.append(f.path)
                    }
                }
                return hits.isEmpty ? "No matches." : hits.joined(separator: "\n") + (hits.count >= maxResults ? "\n… (more results; narrow the search)" : "")
            }
        case "fs_write":
            let url = try policy.resolve(str("path"), write: true)
            let content = str("content")
            let overwrite = args["overwrite"] as? Bool ?? false
            let exists = fm.fileExists(atPath: url.path)
            if exists && !overwrite { throw ToolFail("\(PathPolicy.display(url.path)) already exists. Use fs_edit, or overwrite=true to replace it.") }
            let what = exists ? "Overwrite" : "Create"
            return Plan(summary: "\(what == "Create" ? "Created" : "Overwrote") \(PathPolicy.display(url.path))",
                        approvalSummary: "\(what) \(PathPolicy.display(url.path)) (\(Self.size(content.utf8.count)))\n\(Self.preview(content))",
                        reason: exists ? "This replaces an existing file." : "This creates a new file on your Mac.") { _ in
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: .atomic)
                return "\(what == "Create" ? "Created" : "Overwrote") \(url.path) (\(Self.size(content.utf8.count)))."
            }
        case "fs_edit":
            let url = try policy.resolve(str("path"), write: true)
            let old = str("old_text"), new = str("new_text")
            let all = args["replace_all"] as? Bool ?? false
            guard !old.isEmpty else { throw ToolFail("old_text must not be empty.") }
            guard let data = fm.contents(atPath: url.path), let text = String(data: data, encoding: .utf8) else { throw ToolFail("Cannot read \(PathPolicy.display(url.path)) as text.") }
            let count = text.components(separatedBy: old).count - 1
            if count == 0 { throw ToolFail("old_text was not found in the file. Read the file again and copy the passage exactly.") }
            if count > 1 && !all { throw ToolFail("old_text appears \(count) times. Include more context, or set replace_all=true.") }
            return Plan(summary: "Edited \(PathPolicy.display(url.path))",
                        approvalSummary: "Edit \(PathPolicy.display(url.path)) (\(count) change\(count == 1 ? "" : "s"))\n− \(Self.preview(old, 3))\n+ \(Self.preview(new, 3))",
                        reason: "This changes a file on your Mac.") { _ in
                guard let d = fm.contents(atPath: url.path), let t = String(data: d, encoding: .utf8), t == text else { throw ToolFail("The file changed meanwhile. Read it again.") }
                let out = all ? t.replacingOccurrences(of: old, with: new) : t.replacingCharacters(in: t.range(of: old)!, with: new)
                try Data(out.utf8).write(to: url, options: .atomic)
                return "Edited \(url.path) (\(count) replacement\(count == 1 ? "" : "s"))."
            }
        case "fs_move":
            let from = try policy.resolve(str("from"), write: true)
            let to = try policy.resolve(str("to"), write: true)
            guard fm.fileExists(atPath: from.path) else { throw ToolFail("Not found: \(PathPolicy.display(from.path))") }
            if fm.fileExists(atPath: to.path) { throw ToolFail("\(PathPolicy.display(to.path)) already exists.") }
            return Plan(summary: "Moved \(PathPolicy.display(from.path))", approvalSummary: "Move \(PathPolicy.display(from.path)) → \(PathPolicy.display(to.path))", reason: "This moves or renames a file on your Mac.") { _ in
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                return "Moved \(from.path) to \(to.path)."
            }
        case "fs_trash":
            let url = try policy.resolve(str("path"), write: true)
            guard fm.fileExists(atPath: url.path) else { throw ToolFail("Not found: \(PathPolicy.display(url.path))") }
            return Plan(summary: "Moved \(PathPolicy.display(url.path)) to Trash", approvalSummary: "Move \(PathPolicy.display(url.path)) to the Trash", reason: "Deleting files always asks. You can restore it from the Trash.") { _ in
                var out: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &out)
                return "Moved \(url.path) to the Trash."
            }
        case Self.commandTool:
            let command = str("command").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { throw ToolFail("Missing command.") }
            guard command.count <= 4000 else { throw ToolFail("The command is too long.") }
            let cwd = str("cwd").isEmpty ? (policy.roots.first ?? Paths.home) : try policy.resolve(str("cwd"), write: false)
            let timeout = Double(max(1, min(300, int("timeout_seconds", 60))))
            return Plan(summary: "Ran a command", approvalSummary: "Run in \(PathPolicy.display(cwd.path)):\n\(command)", reason: "Commands can change anything your user account can. Every command asks.") { conv in
                try self.runCommand(command, cwd: cwd, timeout: timeout, conversationId: conv)
            }
        default:
            throw ToolFail("Unknown tool \(name).")
        }
    }

    private func runCommand(_ command: String, cwd: URL, timeout: Double, conversationId: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = cwd
        // A minimal environment: no tokens or keys from the helper's environment.
        let env = ProcessInfo.processInfo.environment
        p.environment = ["HOME": Paths.home.path, "PATH": "/usr/local/bin:/opt/homebrew/bin:\(Paths.home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                         "LANG": env["LANG"] ?? "en_US.UTF-8", "TERM": "dumb", "USER": NSUserName()]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        var data = Data()
        let dataLock = NSLock()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            dataLock.lock(); if data.count < 200_000 { data.append(d) }; dataLock.unlock()
        }
        try p.run()
        setpgid(p.processIdentifier, p.processIdentifier)
        lock.lock(); processes[conversationId] = p; lock.unlock()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        var timedOut = false
        if p.isRunning { timedOut = true; kill(-p.processIdentifier, SIGTERM); p.terminate() }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); processes[conversationId] = nil; lock.unlock()
        dataLock.lock(); var text = String(decoding: data, as: UTF8.self); dataLock.unlock()
        if text.count > 30_000 { text = String(text.prefix(30_000)) + "\n… (output truncated)" }
        return "Exit status \(p.terminationStatus)\(timedOut ? " (stopped after \(Int(timeout))s)" : "").\n<command_output>\n\(text)\n</command_output>"
    }

    static func size(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
    static func preview(_ s: String, _ lines: Int = 6) -> String {
        let l = s.components(separatedBy: "\n")
        let head = l.prefix(lines).map { String($0.prefix(120)) }.joined(separator: "\n")
        return l.count > lines ? head + "\n…" : head
    }
}

/// Decides which paths the agent may touch.
struct PathPolicy {
    let access: String          // "folders" | "full"
    let roots: [URL]

    init(access: String, folders: [String]) {
        self.access = access
        roots = folders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL }
    }

    /// Credential stores and app data that are never available, in any tier.
    static let deniedHomeRelative = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".netrc", ".npmrc", ".pypirc", ".config/gh", ".config/gcloud",
        ".claude", ".claude.json", "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Containers", "Library/Group Containers", "Library/Accounts", "Library/Application Support/SafariAgent",
        "Library/Application Support/Claude", "Library/Application Support/Google", "Library/Application Support/Firefox",
        "Library/Application Support/com.apple.TCC", "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Calendars", "Library/Passes", "Library/Preferences",
    ]

    static func display(_ path: String) -> String {
        let home = Paths.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    func isDenied(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        let home = Paths.home.path
        for d in Self.deniedHomeRelative {
            let full = home + "/" + d
            if p == full || p.hasPrefix(full + "/") { return true }
        }
        let name = url.lastPathComponent
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasSuffix(".keychain-db") || name.hasSuffix(".keychain") { return true }
        return false
    }

    func resolve(_ raw: String, write: Bool) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NativeTools.ToolFail("Missing path.") }
        guard !trimmed.contains("\0") else { throw NativeTools.ToolFail("Invalid path.") }
        var url: URL
        if trimmed.hasPrefix("~") {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else if trimmed.hasPrefix("/") {
            url = URL(fileURLWithPath: trimmed)
        } else {
            url = (roots.first ?? Paths.home).appendingPathComponent(trimmed)
        }
        url = Self.resolveExistingPrefix(url.standardizedFileURL)
        if isDenied(url) { throw NativeTools.ToolFail("\(Self.display(url.path)) is protected (credentials or app data) and not available to the agent.") }
        switch access {
        case "folders":
            guard roots.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }) else {
                throw NativeTools.ToolFail("\(Self.display(url.path)) is outside the folders the user allowed (\(roots.map { Self.display($0.path) }.joined(separator: ", "))).")
            }
        case "full":
            let home = Paths.home.path
            if write && !(url.path == home || url.path.hasPrefix(home + "/")) {
                throw NativeTools.ToolFail("Changes are limited to your home folder.")
            }
        default:
            throw NativeTools.ToolFail("Computer access is turned off.")
        }
        return url
    }

    /// Resolve symlinks in the longest existing prefix, so links can't escape an allowed folder.
    static func resolveExistingPrefix(_ url: URL) -> URL {
        var existing = url
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for r in rest { resolved.appendPathComponent(r) }
        return resolved.standardizedFileURL
    }
}

/// Folder chooser for computer access (main thread).
enum FolderPicker {
    static func choose() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = "Allow Access"
        panel.message = "Choose folders the Orbit agent may read and change. You can remove them at any time."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { $0.resolvingSymlinksInPath().path }
    }
}
