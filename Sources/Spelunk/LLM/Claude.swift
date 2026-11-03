import Foundation

/// The app's Claude features; each has its own model and effort setting.
enum ClaudeTask: String, CaseIterable, Identifiable, Sendable {
    case ask, trace, triage, classify, group, rules, attach

    var id: String { rawValue }
    var modelKey: String { "claude.model.\(rawValue)" }
    var effortKey: String { "claude.effort.\(rawValue)" }
    /// The quick classification pass runs on every new hunk, so it defaults to a cheaper setup.
    var defaultModel: String { [.classify, .group, .rules, .attach].contains(self) ? "sonnet" : "opus" }
    var defaultEffort: String? { self == .classify || self == .rules ? "low" : nil }

    var label: String {
        switch self {
        case .ask: "Questions"
        case .trace: "Traces"
        case .triage: "Review triage"
        case .classify: "Quick classification"
        case .group: "Hunk grouping"
        case .rules: "Rule questions (llm conditions)"
        case .attach: "Attachments"
        }
    }
}

enum ClaudeModels {
    /// CLI aliases resolve to the latest model in each family; full model names also work.
    static let aliases: [(id: String, label: String)] = [
        ("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"),
    ]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func label(_ id: String) -> String { aliases.first { $0.id == id }?.label ?? id }
}

/// Progress events from a running Claude session.
enum ClaudeEvent: Sendable {
    case toolUse(name: String, summary: String)
    case text(String)
}

struct ClaudeResult: Sendable {
    var text: String
    var structured: Data?
    var costUSD: Double
    var durationMs: Int
}

struct ClaudeError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Drives the `claude` CLI in print mode with read-only tools, rooted at the workspace.
///
/// The invocation strips MCP servers, user settings and slash commands: with them loaded the
/// prompt cache creation alone was ~350k tokens per call, without them ~4k.
enum Claude {
    static func model(for task: ClaudeTask) -> String {
        let m = UserDefaults.standard.string(forKey: task.modelKey) ?? ""
        return m.isEmpty ? task.defaultModel : m
    }

    static func effort(for task: ClaudeTask) -> String? {
        let e = UserDefaults.standard.string(forKey: task.effortKey) ?? ""
        return e.isEmpty ? task.defaultEffort : e
    }

    static var binary: String? {
        if let c = UserDefaults.standard.string(forKey: "claudePath"), !c.isEmpty, FileManager.default.isExecutableFile(atPath: c) { return c }
        return Shell.which("claude")
    }

    static func run(
        prompt: String,
        system: String,
        cwd: URL,
        task: ClaudeTask,
        schema: [String: Any]? = nil,
        tools: [String] = ["Read", "Grep", "Glob"],
        model modelOverride: String? = nil,
        readableDirs: [URL] = [],
        onEvent: @escaping @Sendable (ClaudeEvent) -> Void = { _ in }
    ) async throws -> ClaudeResult {
        guard let bin = binary else { throw ClaudeError(message: "claude CLI not found on PATH (set it in Settings)") }
        var args = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            // Sessions often run inside a checkout of someone else's change: never load its project
            // settings, and run no hooks at all.
            "--disable-slash-commands", "--setting-sources", "user", "--settings", #"{"disableAllHooks":true}"#,
            "--model", modelOverride ?? model(for: task),
            "--append-system-prompt", system,
        ]
        if let effort = effort(for: task) { args += ["--effort", effort] }
        for d in readableDirs { args += ["--add-dir", d.path] }
        if tools.isEmpty {
            args += ["--tools", ""]
        } else {
            args += ["--tools", tools.joined(separator: ","), "--allowedTools", tools.joined(separator: ",")]
        }
        if let schema, let data = try? JSONSerialization.data(withJSONObject: schema) {
            args += ["--json-schema", String(decoding: data, as: UTF8.self)]
        }

        let state = StreamState()
        let handle: @Sendable (String) -> Void = { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
            switch obj["type"] as? String {
            case "assistant":
                let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                for c in content {
                    if c["type"] as? String == "tool_use" {
                        let name = c["name"] as? String ?? "tool"
                        let input = c["input"] as? [String: Any] ?? [:]
                        let summary = (input["file_path"] ?? input["pattern"] ?? input["path"] ?? input["command"]).map { "\($0)" } ?? ""
                        onEvent(.toolUse(name: name, summary: summary.replacingOccurrences(of: cwd.path + "/", with: "")))
                    } else if c["type"] as? String == "text", let t = c["text"] as? String, !t.isEmpty {
                        onEvent(.text(t))
                    }
                }
            case "result":
                var r = ClaudeResult(text: obj["result"] as? String ?? "", structured: nil,
                                     costUSD: obj["total_cost_usd"] as? Double ?? 0, durationMs: obj["duration_ms"] as? Int ?? 0)
                if let s = obj["structured_output"], !(s is NSNull) {
                    r.structured = try? JSONSerialization.data(withJSONObject: s)
                }
                state.set(result: r, error: obj["is_error"] as? Bool == true ? (r.text.isEmpty ? "Claude returned an error" : r.text) : nil)
            default: break
            }
        }
        // Chunks arrive in order from one reader thread; split them into complete lines.
        let out = try await ProcessRunner.run(bin, args, cwd: cwd, environment: Shell.environment, stdin: Data(prompt.utf8),
                                              timeout: 1800) { chunk in
            for line in state.lines(appending: chunk) { handle(line) }
        }
        for line in state.lines(appending: Data([10])) { handle(line) }
        let (result, error) = state.outcome
        if let error { throw ClaudeError(message: error) }
        if let result { return result }
        throw ClaudeError(message: "claude exited \(out.status): \(String(decoding: out.stderr.suffix(800), as: UTF8.self))")
    }

    /// Decodes structured output, falling back to the first JSON object embedded in the text.
    static func decode<T: Decodable>(_ type: T.Type, from r: ClaudeResult) throws -> T {
        if let d = r.structured, let v = try? JSONDecoder().decode(T.self, from: d) { return v }
        let text = r.text
        if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
           let v = try? JSONDecoder().decode(T.self, from: Data(text[s...e].utf8)) { return v }
        throw ClaudeError(message: "Could not parse Claude's response: \(text.prefix(300))")
    }
}

/// Line splitting and the final result of one streamed Claude run.
final class StreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var result: ClaudeResult?
    private var error: String?

    func lines(appending d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(d)
        guard let nl = pending.lastIndex(of: 10) else { return [] }
        let lines = String(decoding: pending[..<nl], as: UTF8.self).split(separator: "\n").map(String.init)
        pending = Data(pending[(nl + 1)...])
        return lines
    }

    func set(result r: ClaudeResult, error e: String?) {
        lock.lock(); result = r; error = e; lock.unlock()
    }

    var outcome: (ClaudeResult?, String?) {
        lock.lock(); defer { lock.unlock() }
        return (result, error)
    }
}
