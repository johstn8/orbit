import Foundation
import os

/// Logging. Never log tokens, prompts, page content or model output.
enum Log {
    static let helper = Logger(subsystem: "dev.local.SafariAgent", category: "helper")
    static let claude = Logger(subsystem: "dev.local.SafariAgent", category: "claude")
    static let chatgpt = Logger(subsystem: "dev.local.SafariAgent", category: "chatgpt")
}

typealias JSONObject = [String: Any]

enum JSON {
    static func parse(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? JSONObject
    }
    static func parse(_ string: String) -> JSONObject? { parse(Data(string.utf8)) }
    static func parseAny(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
    static func data(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    }
    static func string(_ obj: Any) -> String { String(decoding: data(obj), as: UTF8.self) }
}

enum Paths {
    /// Real home directory (also correct inside a sandbox).
    static var home: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var support: URL { home.appendingPathComponent("Library/Application Support/SafariAgent", isDirectory: true) }
    static var connectionFile: URL { support.appendingPathComponent("connection.json") }
    static var conversations: URL { support.appendingPathComponent("conversations", isDirectory: true) }
    static var run: URL { support.appendingPathComponent("run", isDirectory: true) }
    static var claudeWorkdir: URL { support.appendingPathComponent("claude-workdir", isDirectory: true) }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Atomically write a file readable only by the current user.
    static func writePrivate(_ data: Data, to url: URL) throws {
        ensure(url.deletingLastPathComponent())
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum Random {
    static func token(bytes: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}

/// Constant-time comparison for secrets.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    if x.count != y.count { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}

struct AgentError: Error, CustomStringConvertible {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var description: String { message }
}
