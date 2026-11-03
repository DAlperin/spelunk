import Foundation
import SwiftTreeSitter

/// Third-party grammars are native code loaded into the app. Each new or rebuilt grammar is first
/// loaded and exercised in a child process; one that crashes, hangs or reports an unsupported ABI
/// there is never loaded into the app. Parses in the app are also bounded by a time limit.
enum GrammarProbe {
    static let argument = "--probe-grammar"
    /// Longest a parse with a third-party grammar may run before it is abandoned.
    static let parseTimeout: TimeInterval = 2

    /// Text with nesting, quotes, escapes and non-ASCII, to shake out scanner bugs.
    static let sample: String = {
        var s = "// probe\n/* block */ # hash\n\"string with \\\" escape\" 'c' `tick` ${x} @attr <tag a=\"b\"/>\n"
        s += "fn f(a: [Int], b: {k: v}) -> (x, y) { if a { return b } else { while (1) { break } } }\n"
        s += "héllo wörld 日本語 🦀 \t\r\n"
        s += String(repeating: "( [ { ", count: 40) + String(repeating: " } ] )", count: 40) + "\n"
        s += String(repeating: "\"unterminated ", count: 3) + "\n"
        return String(repeating: s, count: 8)
    }()

    /// Runs in the child process: exits 0 when the grammar loads and parses the sample.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: argument), args.count > i + 2 else { return }
        let path = args[i + 1], symbol = args[i + 2]
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { fail("dlopen failed: \(String(cString: dlerror()))") }
        guard let sym = dlsym(h, symbol) else { fail("symbol \(symbol) not found") }
        typealias Fn = @convention(c) () -> OpaquePointer
        let lang = Language(language: unsafeBitCast(sym, to: Fn.self)())
        guard lang.ABIVersion >= Language.minimumCompatibleVersion && lang.ABIVersion <= Language.version else {
            fail("grammar ABI \(lang.ABIVersion) is unsupported")
        }
        let parser = Parser()
        guard (try? parser.setLanguage(lang)) != nil else { fail("parser rejected the language") }
        parser.timeout = 5
        guard parser.parse(sample)?.rootNode != nil else { fail("parsing a sample did not finish") }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }

    /// Checks a grammar's dylib in a child process; nil when it passed. Results are remembered per
    /// build of the dylib (path, size and modification time).
    static func check(dylib: URL, symbol: String, in directory: URL) -> String? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dylib.path)
        let stamp = "\(attrs?[.size] ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(symbol)"
        let record = directory.appendingPathComponent("probe.txt")
        if (try? String(contentsOf: record, encoding: .utf8)) == "ok " + stamp { return nil }
        guard let exe = Bundle.main.executablePath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = [argument, dylib.path, symbol]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return "could not start the grammar check: \(error.localizedDescription)" }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()
            return "the grammar did not finish parsing a sample within 10 s"
        }
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return msg.isEmpty ? "the grammar crashed while parsing a sample" : msg
        }
        try? ("ok " + stamp).write(to: record, atomically: true, encoding: .utf8)
        return nil
    }
}
