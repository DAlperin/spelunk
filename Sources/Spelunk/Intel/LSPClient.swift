import Foundation

struct LSPError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Minimal JSON-RPC 2.0 client over a child process's stdio.
final class LSPClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private let writeQueue = DispatchQueue(label: "spelunk.lsp.write")

    var onNotification: (@Sendable (String, Any?) -> Void)?
    var onServerRequest: (@Sendable (String, Any?) -> Any?)?
    var onExit: (@Sendable (Int32, String) -> Void)?
    private let stderrTail = LockedData()

    init(executable: String, args: [String], cwd: URL) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.environment = Shell.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errPipe
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            self?.receive(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.stderrTail.append(d)
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let tail = String(decoding: self.stderrTail.data.suffix(2000), as: UTF8.self)
            self.lock.lock()
            let waiting = self.pending
            self.pending.removeAll()
            self.lock.unlock()
            for (_, c) in waiting { c.resume(throwing: LSPError(message: "language server exited")) }
            self.onExit?(p.terminationStatus, tail)
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func stop() {
        guard process.isRunning else { return }
        Task {
            _ = try? await self.request("shutdown", nil, timeout: 2)
            self.notify("exit", nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            if self.process.isRunning { self.process.terminate() }
        }
    }

    func request(_ method: String, _ params: Any?, timeout: TimeInterval = 60) async throws -> Any? {
        let id = allocateID()
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { msg["params"] = params }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
                lock.lock()
                pending[id] = cont
                lock.unlock()
                send(msg)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.fail(id, LSPError(message: "\(method) timed out after \(Int(timeout))s"))
                }
            }
        } onCancel: {
            self.notify("$/cancelRequest", ["id": id])
            self.fail(id, CancellationError())
        }
    }

    private func allocateID() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

    func notify(_ method: String, _ params: Any?) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        send(msg)
    }

    private func fail(_ id: Int, _ error: Error) {
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        c?.resume(throwing: error)
    }

    private func send(_ msg: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        writeQueue.async { [input] in
            try? input.fileHandleForWriting.write(contentsOf: frame)
        }
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var messages: [[String: Any]] = []
        while true {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { break }
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var length = 0
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer[bodyStart..<bodyEnd]
            buffer = Data(buffer[bodyEnd...])
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { messages.append(obj) }
        }
        lock.unlock()
        for m in messages { dispatch(m) }
    }

    private func dispatch(_ m: [String: Any]) {
        if let method = m["method"] as? String {
            if let id = m["id"] {
                let result = onServerRequest?(method, m["params"]) ?? NSNull()
                send(["jsonrpc": "2.0", "id": id, "result": result])
            } else {
                onNotification?(method, m["params"])
            }
            return
        }
        guard let id = (m["id"] as? Int) ?? (m["id"] as? NSNumber)?.intValue else { return }
        lock.lock()
        let c = pending.removeValue(forKey: id)
        lock.unlock()
        if let err = m["error"] as? [String: Any] {
            c?.resume(throwing: LSPError(message: (err["message"] as? String) ?? "LSP error"))
        } else {
            let r = m["result"]
            c?.resume(returning: (r is NSNull) ? nil : r)
        }
    }
}
