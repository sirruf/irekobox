import Foundation

/// Asks the person at the Mac whether an assistant may do something.
public protocol Approver: Sendable {
    func approve(assistant: String, action: String) async -> Bool
}

/// Approves everything (tests, or when Settings don't ask).
public struct AlwaysApprove: Approver {
    public init() {}
    public func approve(assistant: String, action: String) async -> Bool { true }
}

/// The Model Context Protocol over stdio: one JSON-RPC message per line in,
/// one per line out. Tools are listed and allowed by the assistant's access
/// level, looked up by the key its client was configured with.
public actor MCPServer {
    public static let protocolVersion = "2025-06-18"
    static let supportedVersions: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let tools: [MCPTool]
    private let context: ToolContext
    private let key: String?
    private let settingsURL: URL
    private let activityURL: URL
    private let approver: Approver
    private let version: String
    /// The client's own name, from initialize (for the log when it has no key).
    private var clientName = "An assistant"

    public init(tools: [MCPTool] = ContainerTools.all, context: ToolContext, key: String?,
                settingsURL: URL = AssistantFiles.settings, activityURL: URL = AssistantFiles.activity,
                approver: Approver, version: String = "0.1.0") {
        self.tools = tools
        self.context = context
        self.key = key
        self.settingsURL = settingsURL
        self.activityURL = activityURL
        self.approver = approver
        self.version = version
    }

    /// Read on every request, so a change in Settings applies at once.
    private var settings: AssistantSettings { AssistantFiles.load(from: settingsURL) }
    private var level: AccessLevel { settings.level(forKey: key) }
    private var assistantName: String { settings.assistant(forKey: key)?.name ?? clientName }

    /// Handle one incoming line; returns the line to send back, if any.
    public func handle(_ line: String) async -> String? {
        guard let message = JSON.parse(line) else {
            return Self.error(id: .null, code: -32700, message: "Parse error").line()
        }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            // A response to something we never sent, or junk: nothing to answer.
            return nil
        }
        // Notifications (no id) get no reply.
        guard let id else { return nil }
        let params = message["params"] ?? [:]
        switch method {
        case "initialize":
            return Self.result(id: id, initialize(params)).line()
        case "ping":
            return Self.result(id: id, [:]).line()
        case "tools/list":
            return Self.result(id: id, ["tools": .array(visibleTools.map(\.definition))]).line()
        case "tools/call":
            return Self.result(id: id, await call(params)).line()
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)").line()
        }
    }

    private func initialize(_ params: JSON) -> JSON {
        if let name = params["clientInfo"]?["name"]?.string, !name.isEmpty { clientName = name }
        let requested = params["protocolVersion"]?.string ?? Self.protocolVersion
        let version = Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion
        let level = self.level
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "irekobox", "title": "Irekobox", "version": .string(self.version)],
            "instructions": .string("""
            Containers, images, volumes, networks and local Kubernetes clusters on this Mac (Apple's container runtime). \
            This assistant's access: \(level.title) — \(level.summary) \
            The person at the Mac changes it in Irekobox › Settings › AI Assistants.
            """),
        ]
    }

    private var visibleTools: [MCPTool] {
        let level = self.level
        return tools.filter { $0.level <= level }
    }

    private func call(_ params: JSON) async -> JSON {
        let name = params["name"]?.string ?? ""
        let arguments = params["arguments"] ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            return Self.toolResult("No tool called \(name).", error: true)
        }
        let settings = self.settings
        let level = settings.level(forKey: key)
        let who = settings.assistant(forKey: key)?.name ?? clientName
        let summary = tool.summary(arguments)
        guard tool.level <= level else {
            log(who, tool, summary, .refused)
            return Self.toolResult("""
            Not allowed: this assistant's access is \(level.title), and \(tool.title.lowercased()) needs \(tool.level.title). \
            The person at the Mac can change it in Irekobox › Settings › AI Assistants.
            """, error: true)
        }
        if let check = tool.check {
            do { try await check(arguments, context) } catch {
                log(who, tool, summary, .failed)
                return Self.toolResult(error.localizedDescription, error: true)
            }
        }
        if tool.destructive && settings.askBeforeDeleting {
            let request = tool.ask?(arguments) ?? summary
            guard await approver.approve(assistant: who, action: request) else {
                log(who, tool, summary, .declined)
                return Self.toolResult("The person at the Mac didn't allow this: \(request).", error: true)
            }
        }
        do {
            let text = try await tool.run(arguments, context)
            log(who, tool, summary, .done)
            return Self.toolResult(text, error: false)
        } catch {
            log(who, tool, summary, .failed)
            return Self.toolResult(error.localizedDescription, error: true)
        }
    }

    private func log(_ who: String, _ tool: MCPTool, _ summary: String, _ outcome: AssistantActivity.Outcome) {
        ActivityLog.append(AssistantActivity(assistant: who, tool: tool.name, summary: summary, outcome: outcome), to: activityURL)
    }

    // MARK: - Messages

    static func result(id: JSON, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSON, code: Int, message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    static func toolResult(_ text: String, error: Bool) -> JSON {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(error)]
    }

    /// Serve stdin to stdout until stdin closes.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        for await line in Self.lines(of: input) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let reply = await handle(line) {
                output.write(Data((reply + "\n").utf8))
            }
        }
    }

    static func lines(of handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            Thread {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        continuation.yield(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
                if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                continuation.finish()
            }.start()
        }
    }
}

/// Asks through the app: a distributed notification it answers after the
/// person allows or denies (a notification with buttons). Opens the app if
/// it isn't running; no answer in two minutes means no.
public struct AppApprover: Approver {
    public static let request = Notification.Name("com.irekobox.assistant.approval.request")
    public static let response = Notification.Name("com.irekobox.assistant.approval.response")

    public init() {}

    public func approve(assistant: String, action: String) async -> Bool {
        let id = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        let answer = AsyncStream<Bool> { continuation in
            // Only removed once, when the stream ends.
            nonisolated(unsafe) let observer = center.addObserver(forName: Self.response, object: id, queue: nil) { note in
                continuation.yield((note.userInfo?["approved"] as? Bool) ?? false)
                continuation.finish()
            }
            continuation.onTermination = { _ in center.removeObserver(observer) }
        }
        let open = Process()
        open.executableURL = URL(filePath: "/usr/bin/open")
        open.arguments = ["-g", "-b", "com.irekobox.app"]
        try? open.run()
        open.waitUntilExit()
        // Post a few times while the app may still be starting.
        let poster = Task {
            for _ in 0..<6 {
                center.postNotificationName(Self.request, object: id,
                                            userInfo: ["assistant": assistant, "action": action],
                                            deliverImmediately: true)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { poster.cancel() }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await approved in answer { return approved }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(120))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
