import AppKit

// The same executable serves two roles:
//   SafariAgent --mcp-bridge   stdio MCP server launched by Claude Code
//   SafariAgent                menu bar helper app (default)
if CommandLine.arguments.contains("--mcp-bridge") {
    MCPBridge.run()
}

// Development aid: render the five picker designs to PNG files and exit.
//   Orbit --render-designs <folder>
if let i = CommandLine.arguments.firstIndex(of: "--render-designs"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated { PickerSnapshots.render(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
