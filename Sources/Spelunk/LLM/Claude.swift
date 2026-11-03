import Foundation

/// The app's Claude features; each has its own model and effort setting.
enum ClaudeTask: String, CaseIterable, Identifiable, Sendable {
    case ask, trace, triage, classify, group

    var id: String { rawValue }
    var modelKey: String { "claude.model.\(rawValue)" }
    var effortKey: String { "claude.effort.\(rawValue)" }
    /// The quick classification pass runs on every new hunk, so it defaults to a cheaper setup.
    var defaultModel: String { self == .classify || self == .group ? "sonnet" : "opus" }
    var defaultEffort: String? { self == .classify ? "low" : nil }

    var label: String {
        switch self {
        case .ask: "Questions"
        case .trace: "Traces"
        case .triage: "Review triage"
        case .classify: "Quick classification"
        case .group: "Hunk grouping"
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
        onEvent: @escaping @Sendable (ClaudeEvent) -> Void = { _ in }
    ) async throws -> ClaudeResult {
        guard let bin = binary else { throw ClaudeError(message: "claude CLI not found on PATH (set it in Settings)") }
        var args = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--disable-slash-commands", "--setting-sources", "project",
            "--model", model(for: task),
            "--append-system-prompt", system,
        ]
        if let effort = effort(for: task) { args += ["--effort", effort] }
        if tools.isEmpty {
            args += ["--tools", ""]
        } else {
            args += ["--tools", tools.joined(separator: ","), "--allowedTools", tools.joined(separator: ",")]
        }
        if let schema, let data = try? JSONSerialization.data(withJSONObject: schema) {
            args += ["--json-schema", String(decoding: data, as: UTF8.self)]
        }

        let resultBox = ResultBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ClaudeResult, Error>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = args
                p.currentDirectoryURL = cwd
                p.environment = Shell.environment
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                let pending = LockedData()
                let errData = LockedData()
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
                        if obj["is_error"] as? Bool == true { resultBox.error = r.text.isEmpty ? "Claude returned an error" : r.text }
                        resultBox.result = r
                    default: break
                    }
                }
                out.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    pending.append(d)
                    let all = pending.data
                    guard let nl = all.lastIndex(of: 10) else { return }
                    let lines = String(decoding: all[..<nl], as: UTF8.self).split(separator: "\n")
                    pending.replace(Data(all[(nl + 1)...]))
                    for l in lines { handle(String(l)) }
                }
                err.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }
                p.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    let rest = pending.data + out.fileHandleForReading.readDataToEndOfFile()
                    for l in String(decoding: rest, as: UTF8.self).split(separator: "\n") { handle(String(l)) }
                    if let e = resultBox.error {
                        cont.resume(throwing: ClaudeError(message: e))
                    } else if let r = resultBox.result {
                        cont.resume(returning: r)
                    } else {
                        let stderr = String(decoding: errData.data.suffix(800), as: UTF8.self)
                        cont.resume(throwing: ClaudeError(message: "claude exited \(proc.terminationStatus): \(stderr)"))
                    }
                }
                resultBox.process = p
                do {
                    try p.run()
                    inp.fileHandleForWriting.write(Data(prompt.utf8))
                    try? inp.fileHandleForWriting.close()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            resultBox.process?.terminate()
        }
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

final class ResultBox: @unchecked Sendable {
    var result: ClaudeResult?
    var error: String?
    var process: Process?
}
