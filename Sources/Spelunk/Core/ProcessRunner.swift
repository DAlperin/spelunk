import Foundation

/// Runs child processes to completion. Output pipes are drained on their own threads until EOF, so
/// nothing written before exit is lost; stdin is written off the caller's thread; cancelling the
/// calling task terminates the process (then kills it if it lingers); and a per-tool budget bounds
/// how many of each kind run at once.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Concurrency limits by executable name; anything else shares the default.
    static let budget = ProcessBudget(limits: ["claude": 4, "rust-analyzer": 2, "cargo": 1], defaultLimit: 12)

    /// - Parameter onStdout: called with stdout chunks in order, from a background thread.
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, environment: [String: String],
                    stdin: Data? = nil, timeout: TimeInterval? = nil,
                    onStdout: (@Sendable (Data) -> Void)? = nil) async throws -> Output {
        let tool = URL(fileURLWithPath: exe).lastPathComponent
        try await budget.acquire(tool)
        defer { Task { await budget.release(tool) } }
        try Task.checkCancellation()

        let handle = RunHandle()
        return try await withTaskCancellationHandler {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.environment = environment
            if let cwd { p.currentDirectoryURL = cwd }
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = inp

            let exited = AsyncLatch<Int32>()
            p.terminationHandler = { exited.resolve($0.terminationStatus) }
            guard try handle.start(p) else { throw CancellationError() }

            async let stdoutData: Data = drain(out.fileHandleForReading, onChunk: onStdout)
            async let stderrData: Data = drain(err.fileHandleForReading, onChunk: nil)
            DispatchQueue.global(qos: .userInitiated).async {
                if let stdin, !stdin.isEmpty { try? inp.fileHandleForWriting.write(contentsOf: stdin) }
                try? inp.fileHandleForWriting.close()
            }
            var timer: Task<Void, Never>?
            if let timeout {
                timer = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled { handle.timedOut = true; handle.stop() }
                }
            }
            let status = await exited.value
            timer?.cancel()
            let o = await stdoutData, e = await stderrData
            if handle.timedOut { throw Failure(message: "\(tool) timed out after \(Int(timeout ?? 0))s") }
            try Task.checkCancellation()
            return Output(status: status, stdout: o, stderr: e)
        } onCancel: {
            handle.stop()
        }
    }

    /// Reads a pipe to EOF on a dedicated thread.
    private static func drain(_ fh: FileHandle, onChunk: (@Sendable (Data) -> Void)?) async -> Data {
        await withCheckedContinuation { cont in
            Thread.detachNewThread {
                var all = Data()
                while true {
                    let d = fh.availableData
                    if d.isEmpty { break }
                    if let onChunk { onChunk(d) } else { all.append(d) }
                }
                cont.resume(returning: all)
            }
        }
    }
}

/// The running process, shared with the cancellation handler: stop before start means never start.
final class RunHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    var timedOut = false

    func start(_ p: Process) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        try p.run()
        process = p
        return true
    }

    /// SIGTERM, then SIGKILL two seconds later if the process is still alive.
    func stop() {
        lock.lock()
        stopped = true
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// A value set once and awaited by one or more tasks.
final class AsyncLatch<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: T?
    private var waiters: [CheckedContinuation<T, Never>] = []

    func resolve(_ v: T) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = v
        let w = waiters
        waiters = []
        lock.unlock()
        for c in w { c.resume(returning: v) }
    }

    var value: T {
        get async {
            await withCheckedContinuation { c in
                lock.lock()
                if let r = result { lock.unlock(); c.resume(returning: r); return }
                waiters.append(c)
                lock.unlock()
            }
        }
    }
}

/// Counting semaphores keyed by tool name.
actor ProcessBudget {
    private let limits: [String: Int]
    private let defaultLimit: Int
    private var inUse: [String: Int] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(limits: [String: Int], defaultLimit: Int) {
        self.limits = limits
        self.defaultLimit = defaultLimit
    }

    private func key(_ tool: String) -> String { limits[tool] != nil ? tool : "*" }
    private func limit(_ k: String) -> Int { limits[k] ?? defaultLimit }

    func acquire(_ tool: String) async throws {
        let k = key(tool)
        if inUse[k, default: 0] < limit(k) { inUse[k, default: 0] += 1; return }
        await withCheckedContinuation { waiting[k, default: []].append($0) }
    }

    func release(_ tool: String) {
        let k = key(tool)
        if var w = waiting[k], !w.isEmpty {
            let next = w.removeFirst()
            waiting[k] = w
            next.resume()
        } else {
            inUse[k, default: 1] -= 1
        }
    }
}
