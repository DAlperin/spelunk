import Foundation

struct ShellResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var ok: Bool { status == 0 }
}

struct ShellError: Error, LocalizedError {
    var command: String
    var result: ShellResult
    var errorDescription: String? {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(command) failed (\(result.status)): \(err.isEmpty ? result.stdout.prefix(400).description : err)"
    }
}

/// Runs external tools. Inherits a PATH that includes the usual developer locations, because
/// apps launched from Finder get a minimal PATH.
enum Shell {
    static let searchPath: String = {
        let home = NSHomeDirectory()
        let extra = [
            "\(home)/.cargo/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (existing + extra).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = "0"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        // Never block on an interactive editor; tools fall back to the message they were given.
        env["EDITOR"] = "true"
        env["VISUAL"] = "true"
        env["JJ_EDITOR"] = "true"
        env["GIT_EDITOR"] = "true"
        return env
    }

    /// Runs a short command synchronously; for use off the main thread only.
    static func syncOutput(_ executable: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out
        // Unread pipes fill up and block the child; discard stderr.
        p.standardError = FileHandle.nullDevice
        try p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ShellError(command: executable, result: ShellResult(status: p.terminationStatus, stdout: "", stderr: "")) }
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func which(_ name: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    /// Runs to completion. Cancelling the calling task terminates the process.
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil, timeout: TimeInterval? = 300) async throws -> ShellResult {
        let exe: String
        if executable.hasPrefix("/") { exe = executable } else if let w = which(executable) { exe = w } else {
            throw ShellError(command: executable, result: ShellResult(status: 127, stdout: "", stderr: "\(executable) not found on PATH"))
        }
        let o = try await ProcessRunner.run(exe, args, cwd: cwd, environment: environment, stdin: stdin.map { Data($0.utf8) }, timeout: timeout)
        return ShellResult(status: o.status, stdout: String(decoding: o.stdout, as: UTF8.self), stderr: String(decoding: o.stderr, as: UTF8.self))
    }

    static func output(_ executable: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval? = 300) async throws -> String {
        let r = try await run(executable, args, cwd: cwd, timeout: timeout)
        guard r.ok else { throw ShellError(command: ([executable] + args).joined(separator: " "), result: r) }
        return r.stdout
    }
}

final class LockedData: @unchecked Sendable {
    private var buf = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); buf.append(d); lock.unlock() }
    func replace(_ d: Data) { lock.lock(); buf = d; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buf }
}

extension URL {
    func relativePath(from base: URL) -> String {
        let p = standardizedFileURL.path, b = base.standardizedFileURL.path
        if p == b { return "" }
        if p.hasPrefix(b + "/") { return String(p.dropFirst(b.count + 1)) }
        return p
    }
}

extension String {
    var lastPathComponent: String { (self as NSString).lastPathComponent }
    var pathExtension: String { (self as NSString).pathExtension }
    var deletingLastPathComponent: String { (self as NSString).deletingLastPathComponent }
}

enum AppPaths {
    /// Spelunk's Application Support folder. SPELUNK_SUPPORT_DIR moves it, so a test instance can run
    /// on a repository without touching the data of an instance already open on it.
    static var base: URL {
        ProcessInfo.processInfo.environment["SPELUNK_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spelunk", isDirectory: true)
    }

    /// Per-repository data: the store, caches and checkouts.
    static func support(for root: URL) -> URL {
        let slug = root.lastPathComponent + "-" + String(UInt64(bitPattern: Int64(root.path.stableHash)), radix: 36)
        let dir = base.appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension String {
    /// FNV-1a; `hashValue` is randomized per process so it cannot key on-disk caches.
    var stableHash: Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return Int(bitPattern: UInt(h))
    }
}
