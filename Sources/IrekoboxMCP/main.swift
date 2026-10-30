import Foundation
import ContainerKit
import MCPKit

// Model Context Protocol server for AI assistants (Cursor, Codex CLI and the
// other MCP clients). Their client starts it with stdin/stdout as the channel; the key in
// IREKOBOX_MCP_KEY says which assistant it is and so what it may do
// (Settings › AI Assistants). Embedded in the app bundle next to the agent.

let defaults = UserDefaults(suiteName: "com.irekobox.app")
let binaryPath = defaults?.string(forKey: "binaryPath") ?? ContainerCLI.defaultBinaryPath
let cli = ContainerCLI(binaryPath: binaryPath)
let engine = XPCEngine(fallback: CLIEngine(cli: cli, stream: CLIStream(binaryPath: binaryPath)))
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
let server = MCPServer(context: ToolContext(engine: engine, cli: cli),
                       key: ProcessInfo.processInfo.environment[AssistantClient.keyVariable],
                       approver: AppApprover(), version: version)
await server.serve()
