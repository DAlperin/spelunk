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
        return env
    }

    static func which(_ name: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil, stdin: String? = nil) async throws -> ShellResult {
        let exe: String
        if executable.hasPrefix("/") { exe = executable } else if let w = which(executable) { exe = w } else {
            throw ShellError(command: executable, result: ShellResult(status: 127, stdout: "", stderr: "\(executable) not found on PATH"))
        }
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.environment = environment
            if let cwd { p.currentDirectoryURL = cwd }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let inPipe = Pipe()
            p.standardInput = inPipe
            let outBuf = LockedData(), errBuf = LockedData()
            out.fileHandleForReading.readabilityHandler = { h in outBuf.append(h.availableData) }
            err.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
                errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: ShellResult(
                    status: proc.terminationStatus,
                    stdout: String(decoding: outBuf.data, as: UTF8.self),
                    stderr: String(decoding: errBuf.data, as: UTF8.self)))
            }
            do {
                try p.run()
                if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inPipe.fileHandleForWriting.close()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    static func output(_ executable: String, _ args: [String], cwd: URL? = nil) async throws -> String {
        let r = try await run(executable, args, cwd: cwd)
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
    static func support(for root: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spelunk", isDirectory: true)
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
