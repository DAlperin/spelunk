import Foundation
import Observation

/// rust-analyzer over LSP. Owns the server process for one workspace root.
@MainActor @Observable
final class RustAnalyzer {
    enum Status: Equatable {
        case off, starting, indexing(String), ready, failed(String)

        var label: String {
            switch self {
            case .off: "Off"
            case .starting: "Starting"
            case .indexing(let s): s.isEmpty ? "Indexing" : s
            case .ready: "Ready"
            case .failed(let e): "Failed: \(e)"
            }
        }

        var isUsable: Bool {
            switch self {
            case .ready, .indexing: true
            default: false
            }
        }
    }

    let root: URL
    var status: Status = .off
    var binaryPath: String?
    var version: String?
    private var client: LSPClient?
    private var versions: [String: Int] = [:]
    private var progress: [String: String] = [:]
    private var progressTitles: [String: String] = [:]
    private var quiescent = false

    init(root: URL) { self.root = root }

    nonisolated(unsafe) static let settings: [String: Any] = [
        "checkOnSave": false,
        "cachePriming": ["enable": true],
        "procMacro": ["enable": true],
        "cargo": ["buildScripts": ["enable": true]],
        "lens": ["enable": false],
        "inlayHints": ["typeHints": ["enable": false]],
    ]

    /// True once the server has finished its startup indexing.
    var isWarm: Bool { status == .ready }

    nonisolated(unsafe) private static var cachedBinary: String??

    /// Locates rust-analyzer off the main thread; the result is cached for the process.
    nonisolated static func resolveBinary() async -> String? {
        if let c = cachedBinary { return c }
        let found = await Task.detached(priority: .userInitiated) { locateBinary() }.value
        cachedBinary = .some(found)
        return found
    }

    nonisolated static func locateBinary() -> String? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "rustAnalyzerPath"), !custom.isEmpty,
           fm.isExecutableFile(atPath: custom) { return custom }
        var candidates: [String] = []
        let home = NSHomeDirectory()
        if let p = Shell.which("rust-analyzer") { candidates.append(p) }
        let zed = "\(home)/Library/Application Support/Zed/languages/rust-analyzer"
        if let items = try? fm.contentsOfDirectory(atPath: zed) {
            for i in items.sorted(by: >) where !i.hasSuffix(".metadata") { candidates.append("\(zed)/\(i)") }
        }
        let vscode = "\(home)/.vscode/extensions"
        if let items = try? fm.contentsOfDirectory(atPath: vscode) {
            for i in items.sorted(by: >) where i.hasPrefix("rust-lang.rust-analyzer") {
                candidates.append("\(vscode)/\(i)/server/rust-analyzer")
            }
        }
        candidates.append("/opt/homebrew/bin/rust-analyzer")
        for c in candidates where fm.isExecutableFile(atPath: c) {
            // The rustup proxy exists even when the component is not installed; probe it.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: c)
            p.arguments = ["--version"]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.environment = Shell.environment
            guard (try? p.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate(); continue }
            if p.terminationStatus == 0 { return c }
        }
        return nil
    }

    func start() {
        guard client == nil, status != .starting else { return }
        status = .starting
        Task {
            let bin = await Self.resolveBinary()
            self.launch(bin)
        }
    }

    private func launch(_ bin: String?) {
        guard let bin else {
            status = .failed("rust-analyzer not found (set a path in Settings)")
            return
        }
        binaryPath = bin
        status = .starting
        let c = LSPClient(executable: bin, args: [], cwd: root)
        if Log.enabled, let filter = ProcessInfo.processInfo.environment["SPELUNK_RA_LOG"] { c.environment["RA_LOG"] = filter }
        c.onNotification = { [weak self] method, params in
            Task { @MainActor in self?.handleNotification(method, params) }
        }
        c.onServerRequest = { method, params in
            switch method {
            case "workspace/configuration":
                // Answering with null makes rust-analyzer treat its configuration as changed and
                // reload the workspace; return the same settings it was initialized with.
                let items = ((params as? [String: Any])?["items"] as? [[String: Any]]) ?? []
                return items.map { item -> Any in
                    (item["section"] as? String) == "rust-analyzer" ? RustAnalyzer.settings : NSNull()
                }
            default:
                return NSNull()
            }
        }
        c.onExit = { [weak self] code, tail in
            Task { @MainActor in
                guard let self else { return }
                self.client = nil
                if case .off = self.status { return }
                let lastLine = tail.split(separator: "\n").last.map(String.init) ?? ""
                self.status = .failed("exited \(code) \(lastLine)")
            }
        }
        do {
            try c.start()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        client = c
        Task {
            do {
                let params: [String: Any] = [
                    "processId": ProcessInfo.processInfo.processIdentifier,
                    "rootUri": root.absoluteString,
                    "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
                    "capabilities": [
                        "general": ["positionEncodings": ["utf-16"]],
                        "window": ["workDoneProgress": true],
                        "textDocument": [
                            "hover": ["contentFormat": ["markdown", "plaintext"]],
                            "definition": ["linkSupport": false],
                            "references": [:],
                            "implementation": ["linkSupport": false],
                            "callHierarchy": [:],
                            "documentHighlight": [:],
                            "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                        ],
                        "experimental": ["serverStatusNotification": true],
                    ] as [String: Any],
                    "initializationOptions": RustAnalyzer.settings,
                ]
                let result = try await c.request("initialize", params, timeout: 120)
                if let info = (result as? [String: Any])?["serverInfo"] as? [String: Any] {
                    self.version = info["version"] as? String
                }
                c.notify("initialized", [String: Any]())
                if case .starting = self.status { self.status = .indexing("Loading workspace") }
            } catch {
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        let c = client
        client = nil
        status = .off
        c?.stop()
    }

    func restart() {
        stop()
        versions.removeAll()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.start()
        }
    }

    private func handleNotification(_ method: String, _ params: Any?) {
        let p = params as? [String: Any]
        switch method {
        case "$/progress":
            guard let token = p?["token"].map({ "\($0)" }), let value = p?["value"] as? [String: Any] else { return }
            let kind = value["kind"] as? String
            if kind != "report" { Log.debug("ra progress \(kind ?? "?") \(value["title"] as? String ?? progressTitles[token] ?? token) \(value["message"] as? String ?? "")") }
            if kind == "end" {
                progress.removeValue(forKey: token)
                progressTitles.removeValue(forKey: token)
            } else {
                // Reports carry only the latest message; the title arrives once, with "begin".
                if let t = value["title"] as? String { progressTitles[token] = t }
                var s = progressTitles[token] ?? ""
                if let msg = value["message"] as? String, !msg.isEmpty { s += " \(msg)" }
                if let pct = value["percentage"] as? Int { s += " \(pct)%" }
                progress[token] = s
            }
            refreshStatus()
        case "experimental/serverStatus":
            quiescent = (p?["quiescent"] as? Bool) ?? false
            Log.debug("ra serverStatus quiescent=\(quiescent) health=\(p?["health"] as? String ?? "?") \(p?["message"] as? String ?? "")")
            if let health = p?["health"] as? String, health == "error", let msg = p?["message"] as? String {
                status = .failed(msg)
                return
            }
            refreshStatus()
        default:
            break
        }
    }

    private func refreshStatus() {
        guard client != nil else { return }
        if case .failed = status { return }
        if let first = progress.values.sorted().first {
            status = .indexing(first)
        } else if quiescent {
            status = .ready
        } else {
            status = .indexing("")
        }
    }

    // MARK: Documents

    func uri(for path: String) -> String {
        path.hasPrefix("/") ? URL(fileURLWithPath: path).absoluteString : root.appendingPathComponent(path).absoluteString
    }

    func path(fromURI uri: String) -> String {
        guard let u = URL(string: uri) else { return uri }
        return u.standardizedFileURL.relativePath(from: root)
    }

    func didOpen(path: String, text: String, language: SourceLanguage) {
        guard let client, language == .rust else { return }
        if let v = versions[path] {
            versions[path] = v + 1
            client.notify("textDocument/didChange", [
                "textDocument": ["uri": uri(for: path), "version": v + 1],
                "contentChanges": [["text": text]],
            ])
            return
        }
        versions[path] = 1
        client.notify("textDocument/didOpen", [
            "textDocument": ["uri": uri(for: path), "languageId": "rust", "version": 1, "text": text],
        ])
    }

    private func pos(_ p: SourcePos) -> [String: Any] { ["line": p.line, "character": p.col] }

    private func docPos(_ path: String, _ p: SourcePos) -> [String: Any] {
        ["textDocument": ["uri": uri(for: path)], "position": pos(p)]
    }

    nonisolated static func parseRange(_ any: Any?) -> SourceRange? {
        guard let r = any as? [String: Any], let s = r["start"] as? [String: Any], let e = r["end"] as? [String: Any],
              let sl = s["line"] as? Int, let sc = s["character"] as? Int,
              let el = e["line"] as? Int, let ec = e["character"] as? Int else { return nil }
        return SourceRange(start: SourcePos(line: sl, col: sc), end: SourcePos(line: el, col: ec))
    }

    private func locations(_ any: Any?) -> [CodeLocation] {
        var arr: [[String: Any]] = []
        if let a = any as? [[String: Any]] { arr = a } else if let d = any as? [String: Any] { arr = [d] }
        return arr.compactMap { l in
            let uri = (l["uri"] as? String) ?? (l["targetUri"] as? String)
            let range = Self.parseRange(l["range"] ?? l["targetSelectionRange"])
            guard let uri, let range else { return nil }
            return CodeLocation(path: path(fromURI: uri), range: range)
        }
    }

    private func call(_ method: String, _ params: Any, timeout: TimeInterval = 30) async throws -> Any? {
        guard let client, status.isUsable else { throw LSPError(message: "rust-analyzer is \(status.label.lowercased())") }
        return try await client.request(method, params, timeout: timeout)
    }

    func definition(path: String, at p: SourcePos) async throws -> [CodeLocation] {
        locations(try await call("textDocument/definition", docPos(path, p)))
    }

    func typeDefinition(path: String, at p: SourcePos) async throws -> [CodeLocation] {
        locations(try await call("textDocument/typeDefinition", docPos(path, p)))
    }

    func implementations(path: String, at p: SourcePos) async throws -> [CodeLocation] {
        locations(try await call("textDocument/implementation", docPos(path, p)))
    }

    func references(path: String, at p: SourcePos, includeDeclaration: Bool = true) async throws -> [CodeLocation] {
        var params = docPos(path, p)
        params["context"] = ["includeDeclaration": includeDeclaration]
        return locations(try await call("textDocument/references", params, timeout: 120))
    }

    func hover(path: String, at p: SourcePos) async throws -> String? {
        guard let r = try await call("textDocument/hover", docPos(path, p)) as? [String: Any] else { return nil }
        if let c = r["contents"] as? [String: Any] { return c["value"] as? String }
        if let s = r["contents"] as? String { return s }
        if let arr = r["contents"] as? [Any] {
            return arr.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["value"] as? String) }.joined(separator: "\n\n")
        }
        return nil
    }

    struct WorkspaceSymbol {
        var name: String
        var kind: Int
        var container: String?
        var location: CodeLocation
    }

    func workspaceSymbols(_ query: String) async throws -> [WorkspaceSymbol] {
        let r = try await call("workspace/symbol", ["query": query], timeout: 10) as? [[String: Any]] ?? []
        return r.compactMap { s in
            guard let name = s["name"] as? String, let loc = s["location"] as? [String: Any],
                  let uri = loc["uri"] as? String, let range = Self.parseRange(loc["range"]) else { return nil }
            return WorkspaceSymbol(name: name, kind: s["kind"] as? Int ?? 0, container: s["containerName"] as? String,
                                   location: CodeLocation(path: path(fromURI: uri), range: range))
        }
    }

    func documentHighlights(path: String, at p: SourcePos) async throws -> [SourceRange] {
        let r = try await call("textDocument/documentHighlight", docPos(path, p), timeout: 5) as? [[String: Any]] ?? []
        return r.compactMap { Self.parseRange($0["range"]) }
    }

    func prepareCallHierarchy(path: String, at p: SourcePos) async throws -> [LSPPayload] {
        let r = try await call("textDocument/prepareCallHierarchy", docPos(path, p)) as? [[String: Any]] ?? []
        return r.map(LSPPayload.init)
    }

    struct CallEdge {
        var item: LSPPayload
        var name: String
        var detail: String
        var location: CodeLocation
        var callSites: [CodeLocation]
    }

    func calls(_ direction: CallDirection, of item: LSPPayload) async throws -> [CallEdge] {
        let method = direction == .incoming ? "callHierarchy/incomingCalls" : "callHierarchy/outgoingCalls"
        let r = try await call(method, ["item": item.value], timeout: 60) as? [[String: Any]] ?? []
        let itemURI = item.value["uri"] as? String ?? ""
        return r.compactMap { edge in
            guard let other = (edge[direction == .incoming ? "from" : "to"]) as? [String: Any],
                  let uri = other["uri"] as? String,
                  let sel = Self.parseRange(other["selectionRange"]) else { return nil }
            let ranges = (edge["fromRanges"] as? [Any] ?? []).compactMap(Self.parseRange)
            // Incoming fromRanges are in the caller's file; outgoing fromRanges are in the current item's file.
            let siteURI = direction == .incoming ? uri : itemURI
            return CallEdge(
                item: LSPPayload(value: other),
                name: other["name"] as? String ?? "?",
                detail: other["detail"] as? String ?? "",
                location: CodeLocation(path: path(fromURI: uri), range: sel),
                callSites: ranges.map { CodeLocation(path: path(fromURI: siteURI), range: $0) })
        }
    }

    static func payload(name: String, path: String, root: URL, range: SourceRange) -> LSPPayload {
        let uri = path.hasPrefix("/") ? URL(fileURLWithPath: path).absoluteString : root.appendingPathComponent(path).absoluteString
        let r: [String: Any] = [
            "start": ["line": range.start.line, "character": range.start.col],
            "end": ["line": range.end.line, "character": range.end.col],
        ]
        return LSPPayload(value: ["name": name, "kind": 12, "uri": uri, "range": r, "selectionRange": r])
    }
}
