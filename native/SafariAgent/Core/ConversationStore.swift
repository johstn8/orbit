import Foundation

struct Block: Codable {
    var type: String          // text | tool | error | notice
    var text: String?
    var id: String?
    var name: String?
    var summary: String?
    var status: String?
    var detail: String?

    func json() -> JSONObject {
        var o: JSONObject = ["type": type]
        if let text { o["text"] = text }
        if let id { o["id"] = id }
        if let name { o["name"] = name }
        if let summary { o["summary"] = summary }
        if let status { o["status"] = status }
        if let detail { o["detail"] = detail }
        return o
    }
}

struct UIMessage: Codable {
    var id: String
    var role: String
    var blocks: [Block]
    var createdAt: Double

    func json() -> JSONObject { ["id": id, "role": role, "blocks": blocks.map { $0.json() }, "createdAt": createdAt] }
}

struct Conversation: Codable {
    var id: String
    var title: String
    var provider: String
    var model: String?
    var createdAt: Double
    var updatedAt: Double
    var messages: [UIMessage]
    /// Claude Code session id used to resume the conversation.
    var claudeSessionId: String?

    func summaryJSON() -> JSONObject {
        var o: JSONObject = ["id": id, "title": title, "provider": provider, "updatedAt": updatedAt]
        if let model { o["model"] = model }
        return o
    }
    func json() -> JSONObject {
        var o = summaryJSON()
        o["messages"] = messages.map { $0.json() }
        return o
    }

    /// Apply a streamed event to the UI transcript (mirrors the extension logic).
    mutating func apply(_ ev: JSONObject) {
        let kind = ev["kind"] as? String ?? ""
        func idx(_ mid: String?) -> Int? {
            guard let mid else { return nil }
            if let i = messages.firstIndex(where: { $0.id == mid }) { return i }
            messages.append(UIMessage(id: mid, role: "assistant", blocks: [], createdAt: Date().timeIntervalSince1970 * 1000))
            return messages.count - 1
        }
        switch kind {
        case "message_start": _ = idx(ev["messageId"] as? String)
        case "text_delta":
            guard let i = idx(ev["messageId"] as? String), let t = ev["text"] as? String else { return }
            if let last = messages[i].blocks.last, last.type == "text" {
                messages[i].blocks[messages[i].blocks.count - 1].text = (last.text ?? "") + t
            } else {
                messages[i].blocks.append(Block(type: "text", text: t))
            }
        case "tool_start":
            guard let i = idx(ev["messageId"] as? String) else { return }
            messages[i].blocks.append(Block(type: "tool", id: ev["toolId"] as? String, name: ev["name"] as? String, summary: ev["summary"] as? String, status: "running"))
        case "tool_end":
            guard let i = idx(ev["messageId"] as? String) else { return }
            if let j = messages[i].blocks.firstIndex(where: { $0.type == "tool" && $0.id == (ev["toolId"] as? String) }) {
                messages[i].blocks[j].status = ev["status"] as? String
                if let d = ev["detail"] as? String { messages[i].blocks[j].detail = d }
            }
        case "error":
            let text = ev["text"] as? String ?? "Error"
            if let i = idx(ev["messageId"] as? String) { messages[i].blocks.append(Block(type: "error", text: text)) }
            else { messages.append(UIMessage(id: "err\(Int(Date().timeIntervalSince1970 * 1000))", role: "assistant", blocks: [Block(type: "error", text: text)], createdAt: Date().timeIntervalSince1970 * 1000)) }
        case "done":
            updatedAt = Date().timeIntervalSince1970 * 1000
            if ev["cancelled"] as? Bool == true, let i = idx(ev["messageId"] as? String) {
                // Mark tools that never finished.
                for j in messages[i].blocks.indices where messages[i].blocks[j].status == "running" { messages[i].blocks[j].status = "error" }
                messages[i].blocks.append(Block(type: "notice", text: "Stopped."))
            }
        default: break
        }
    }
}

/// Persists conversations as JSON files (0600) in Application Support.
/// Provider-specific state that is not shown in the UI (ChatGPT input items)
/// lives in a sibling file.
final class ConversationStore {
    private var cache: [String: Conversation] = [:]
    private var loaded = false
    private let dir = Paths.conversations

    private func url(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }
    private func itemsURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).items.json") }

    private static func validId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private func loadAll() {
        guard !loaded else { return }
        loaded = true
        Paths.ensure(dir)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasSuffix(".items.json") {
            if let d = try? Data(contentsOf: f), let c = try? JSONDecoder().decode(Conversation.self, from: d) {
                cache[c.id] = c
            }
        }
    }

    func list() -> [Conversation] {
        loadAll()
        return cache.values.filter { !$0.messages.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func get(_ id: String) -> Conversation? {
        guard Self.validId(id) else { return nil }
        loadAll()
        return cache[id]
    }

    func create(provider: String, model: String?, title: String) -> Conversation {
        loadAll()
        let now = Date().timeIntervalSince1970 * 1000
        let c = Conversation(id: UUID().uuidString.lowercased(), title: title, provider: provider, model: model, createdAt: now, updatedAt: now, messages: [])
        cache[c.id] = c
        return c
    }

    func update(_ c: Conversation, persist: Bool = true) {
        cache[c.id] = c
        if persist { save(c) }
    }

    func save(_ c: Conversation) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        try? Paths.writePrivate(d, to: url(c.id))
    }

    func delete(_ id: String) {
        guard Self.validId(id) else { return }
        cache[id] = nil
        try? FileManager.default.removeItem(at: url(id))
        try? FileManager.default.removeItem(at: itemsURL(id))
    }

    func loadItems(_ id: String) -> [JSONObject] {
        guard Self.validId(id), let d = try? Data(contentsOf: itemsURL(id)), let arr = JSON.parseAny(d) as? [JSONObject] else { return [] }
        return arr
    }

    func saveItems(_ id: String, _ items: [JSONObject]) {
        guard Self.validId(id) else { return }
        try? Paths.writePrivate(JSON.data(items), to: itemsURL(id))
    }
}
