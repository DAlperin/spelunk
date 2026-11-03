import Foundation
import Observation

struct Diagnostic: Identifiable, Hashable, Sendable {
    enum Level: String, Sendable { case error, warning, note, help }
    var id = UUID()
    var level: Level
    var message: String
    var code: String?
    var location: CodeLocation
    var rendered: String?
}

/// Static analysis through `cargo clippy --message-format=json`.
@MainActor @Observable
final class ClippyService {
    enum State: Equatable { case idle, running(String), done(Date), failed(String) }

    let root: URL
    var state: State = .idle
    var diagnostics: [Diagnostic] = []
    var byFile: [String: [Diagnostic]] = [:]
    var scope: String = UserDefaults.standard.string(forKey: "clippyScope") ?? "--workspace"
    private var process: Process?

    init(root: URL) { self.root = root }

    private var runGeneration = 0

    func run() {
        process?.terminate()
        runGeneration += 1
        let gen = runGeneration
        state = .running("Starting cargo clippy")
        diagnostics = []
        byFile = [:]
        let p = Process()
        guard let cargo = Shell.which("cargo") else { state = .failed("cargo not found"); return }
        p.executableURL = URL(fileURLWithPath: cargo)
        var args = ["clippy", "--message-format=json", "--all-targets"]
        args += scope.split(separator: " ").map(String.init)
        p.arguments = args
        p.currentDirectoryURL = root
        p.environment = Shell.environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let lineBuf = LockedData()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lineBuf.append(d)
            let all = lineBuf.data
            guard let lastNL = all.lastIndex(of: 10) else { return }
            let complete = all[..<lastNL]
            let rest = all[(lastNL + 1)...]
            let lines = String(decoding: complete, as: UTF8.self).split(separator: "\n").map(String.init)
            lineBuf.reset(Data(rest))
            Task { @MainActor in if self?.runGeneration == gen { self?.consume(lines) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let last = String(decoding: d, as: UTF8.self).split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            Task { @MainActor in if case .running = self?.state, !last.isEmpty { self?.state = .running(String(last.prefix(90))) } }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let code = proc.terminationStatus
            Task { @MainActor in
                guard let self, self.runGeneration == gen else { return }
                self.process = nil
                self.state = (code == 0 || !self.diagnostics.isEmpty) ? .done(Date()) : .failed("cargo clippy exited \(code)")
            }
        }
        do { try p.run(); process = p } catch { state = .failed(error.localizedDescription) }
    }

    func cancel() { process?.terminate() }

    private func consume(_ lines: [String]) {
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["reason"] as? String == "compiler-message",
                  let msg = obj["message"] as? [String: Any],
                  let levelStr = msg["level"] as? String,
                  let level = Diagnostic.Level(rawValue: levelStr == "failure-note" ? "note" : levelStr),
                  level == .error || level == .warning,
                  let spans = msg["spans"] as? [[String: Any]],
                  let span = spans.first(where: { $0["is_primary"] as? Bool == true }) ?? spans.first,
                  let file = span["file_name"] as? String,
                  let ls = span["line_start"] as? Int, let cs = span["column_start"] as? Int,
                  let le = span["line_end"] as? Int, let ce = span["column_end"] as? Int else { continue }
            let path = file.hasPrefix("/") ? URL(fileURLWithPath: file).relativePath(from: root) : file
            let d = Diagnostic(
                level: level, message: msg["message"] as? String ?? "",
                code: (msg["code"] as? [String: Any])?["code"] as? String,
                location: CodeLocation(path: path, range: SourceRange(start: SourcePos(line: ls - 1, col: cs - 1), end: SourcePos(line: le - 1, col: ce - 1))),
                rendered: msg["rendered"] as? String)
            if diagnostics.contains(where: { $0.location == d.location && $0.message == d.message }) { continue }
            diagnostics.append(d)
            byFile[path, default: []].append(d)
        }
    }
}

extension LockedData {
    func reset(_ d: Data) { replace(d) }
}
