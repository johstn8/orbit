import SafariServices
import AppKit
import os

/// Native side of the Safari web extension (runs sandboxed inside Safari's
/// extension host). Its only job is to hand the extension the helper's
/// loopback port and per-launch secret, launching the helper app if needed.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let log = Logger(subsystem: "dev.local.SafariAgent.Extension", category: "handler")
    private static let appBundleId = "dev.local.SafariAgent"

    private static var connectionFile: URL {
        var home = FileManager.default.homeDirectoryForCurrentUser
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = URL(fileURLWithPath: String(cString: dir)) }
        return home.appendingPathComponent("Library/Application Support/SafariAgent/connection.json")
    }

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let type = message?["type"] as? String ?? ""
        // Safari runs one extension instance per profile and tells us which one is asking.
        let profile = Self.profileId(item?.userInfo?[SFExtensionProfileKey])
        DispatchQueue.global().async {
            var reply: [String: Any]
            switch type {
            case "connection_info":
                reply = Self.connectionInfo()
                reply["profile"] = profile
                reply["profileKeyPresent"] = item?.userInfo?[SFExtensionProfileKey] != nil
            default: reply = ["error": "unknown request"]
            }
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: reply]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }
    }

    /// The Safari profile identifier (a UUID) of the extension instance that sent the request.
    static func profileId(_ raw: Any?) -> String {
        if let u = raw as? UUID { return u.uuidString }
        if let u = raw as? NSUUID { return u.uuidString }
        if let s = raw as? String, !s.isEmpty { return s }
        return "default"
    }

    private static func readInfo() -> [String: Any]? {
        guard let d = try? Data(contentsOf: connectionFile),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              o["port"] is Int, o["token"] is String else { return nil }
        return o
    }

    private static func helperRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleId).isEmpty
    }

    private static func launchHelper() {
        // Prefer the copy macOS knows as Orbit (the installed one): the extension itself may
        // run from a stale build folder. Otherwise use the app that contains this extension
        // (<App>.app/Contents/PlugIns/<Ext>.appex).
        let container = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleId)
        let appURL = registered.flatMap { $0.path.contains("/DerivedData/") ? nil : $0 } ?? container
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.arguments = ["--background"]
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error { log.error("could not launch helper: \(error.localizedDescription, privacy: .public)") }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
    }

    static func connectionInfo() -> [String: Any] {
        if helperRunning(), let info = readInfo() {
            return ["port": info["port"]!, "token": info["token"]!]
        }
        let before = (try? FileManager.default.attributesOfItem(atPath: connectionFile.path)[.modificationDate] as? Date) ?? .distantPast
        launchHelper()
        // Wait for the freshly launched helper to publish its connection file.
        for _ in 0..<40 {
            usleep(150_000)
            let mod = (try? FileManager.default.attributesOfItem(atPath: connectionFile.path)[.modificationDate] as? Date) ?? .distantPast
            if mod > before, let info = readInfo() {
                return ["port": info["port"]!, "token": info["token"]!]
            }
        }
        return ["error": "The Safari Agent helper app is not running. Open “Safari Agent” from your Applications folder."]
    }
}
