import AppKit

// The same executable serves two roles:
//   SafariAgent --mcp-bridge   stdio MCP server launched by Claude Code
//   SafariAgent                menu bar helper app (default)
if CommandLine.arguments.contains("--mcp-bridge") {
    MCPBridge.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
