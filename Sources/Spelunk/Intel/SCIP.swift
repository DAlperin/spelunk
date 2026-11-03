import Foundation
import Observation

/// Protobuf wire-format reader, sufficient for the SCIP schema.
struct ProtoReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var pos: Int
    let end: Int

    init(_ bytes: UnsafeBufferPointer<UInt8>, start: Int = 0, end: Int? = nil) {
        self.bytes = bytes; self.pos = start; self.end = end ?? bytes.count
    }

    var atEnd: Bool { pos >= end }

    mutating func varint() -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while pos < end {
            let b = bytes[pos]; pos += 1
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    mutating func tag() -> (field: Int, wire: Int) {
        let t = varint()
        return (Int(t >> 3), Int(t & 7))
    }

    mutating func lengthDelimited() -> ProtoReader {
        let len = Int(varint())
        let r = ProtoReader(bytes, start: pos, end: min(pos + len, end))
        pos = min(pos + len, end)
        return r
    }

    mutating func string() -> String {
        let r = lengthDelimited()
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[r.pos..<r.end]), as: UTF8.self)
    }

    mutating func skip(_ wire: Int) {
        switch wire {
        case 0: _ = varint()
        case 1: pos += 8
        case 2: pos += Int(varint())
        case 5: pos += 4
        default: pos = end
        }
    }

    mutating func packedInts(wire: Int) -> [Int] {
        if wire == 2 {
            var sub = lengthDelimited()
            var out: [Int] = []
            while !sub.atEnd { out.append(Int(Int32(truncatingIfNeeded: sub.varint()))) }
            return out
        }
        return [Int(Int32(truncatingIfNeeded: varint()))]
    }
}

struct SCIPOccurrence: Sendable {
    var line: Int
    var startCol: Int
    var endLine: Int
    var endCol: Int
    var symbol: String
    var roles: Int
    var enclosing: [Int]
    var isDefinition: Bool { roles & 1 != 0 }
}

struct SCIPRelationship: Sendable {
    var symbol: String
    var isReference: Bool
    var isImplementation: Bool
    var isTypeDefinition: Bool
}

struct SCIPSymbolInfo: Sendable {
    var symbol: String
    var documentation: [String] = []
    var relationships: [SCIPRelationship] = []
    var kind: Int = 0
    var displayName: String = ""
}

struct SCIPDocument: Sendable {
    var path: String
    var occurrences: [SCIPOccurrence] = []
    var positionEncoding: Int = 0
}

/// Decoded SCIP index with lookup tables for navigation.
final class SCIPIndex: @unchecked Sendable {
    let toolName: String
    let toolVersion: String
    let documents: [String: SCIPDocument]
    let symbols: [String: SCIPSymbolInfo]
    let occurrencesBySymbol: [String: [(path: String, index: Int)]]
    let implementors: [String: [String]]

    init(data: Data) {
        var docs: [String: SCIPDocument] = [:]
        var syms: [String: SCIPSymbolInfo] = [:]
        var tool = "", version = ""
        data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            var r = ProtoReader(buf)
            while !r.atEnd {
                let (f, w) = r.tag()
                switch (f, w) {
                case (1, 2):
                    var m = r.lengthDelimited()
                    while !m.atEnd {
                        let (mf, mw) = m.tag()
                        if mf == 2 && mw == 2 {
                            var t = m.lengthDelimited()
                            while !t.atEnd {
                                let (tf, tw) = t.tag()
                                if tf == 1 && tw == 2 { tool = t.string() } else if tf == 2 && tw == 2 { version = t.string() } else { t.skip(tw) }
                            }
                        } else { m.skip(mw) }
                    }
                case (2, 2):
                    var d = r.lengthDelimited()
                    let doc = Self.decodeDocument(&d, symbols: &syms)
                    docs[doc.path] = doc
                case (3, 2):
                    var s = r.lengthDelimited()
                    let info = Self.decodeSymbol(&s)
                    if syms[info.symbol] == nil { syms[info.symbol] = info }
                default:
                    r.skip(w)
                }
            }
        }
        var bySym: [String: [(String, Int)]] = [:]
        for (path, doc) in docs {
            for (i, o) in doc.occurrences.enumerated() where !o.symbol.hasPrefix("local ") {
                bySym[o.symbol, default: []].append((path, i))
            }
        }
        var impls: [String: [String]] = [:]
        for (sym, info) in syms {
            for rel in info.relationships where rel.isImplementation { impls[rel.symbol, default: []].append(sym) }
        }
        documents = docs
        symbols = syms
        occurrencesBySymbol = bySym.mapValues { $0.map { (path: $0.0, index: $0.1) } }
        implementors = impls
        toolName = tool
        toolVersion = version
    }

    private static func decodeDocument(_ r: inout ProtoReader, symbols: inout [String: SCIPSymbolInfo]) -> SCIPDocument {
        var doc = SCIPDocument(path: "")
        while !r.atEnd {
            let (f, w) = r.tag()
            switch (f, w) {
            case (1, 2): doc.path = r.string()
            case (2, 2):
                var o = r.lengthDelimited()
                if let occ = decodeOccurrence(&o) { doc.occurrences.append(occ) }
            case (3, 2):
                var s = r.lengthDelimited()
                let info = decodeSymbol(&s)
                symbols[info.symbol] = info
            case (6, 0): doc.positionEncoding = Int(r.varint())
            default: r.skip(w)
            }
        }
        return doc
    }

    private static func decodeOccurrence(_ r: inout ProtoReader) -> SCIPOccurrence? {
        var range: [Int] = [], symbol = "", roles = 0, enclosing: [Int] = []
        while !r.atEnd {
            let (f, w) = r.tag()
            switch f {
            case 1: range += r.packedInts(wire: w)
            case 2 where w == 2: symbol = r.string()
            case 3 where w == 0: roles = Int(r.varint())
            case 7: enclosing += r.packedInts(wire: w)
            default: r.skip(w)
            }
        }
        guard !symbol.isEmpty else { return nil }
        if range.count == 3 { return SCIPOccurrence(line: range[0], startCol: range[1], endLine: range[0], endCol: range[2], symbol: symbol, roles: roles, enclosing: enclosing) }
        if range.count == 4 { return SCIPOccurrence(line: range[0], startCol: range[1], endLine: range[2], endCol: range[3], symbol: symbol, roles: roles, enclosing: enclosing) }
        return nil
    }

    private static func decodeSymbol(_ r: inout ProtoReader) -> SCIPSymbolInfo {
        var info = SCIPSymbolInfo(symbol: "")
        while !r.atEnd {
            let (f, w) = r.tag()
            switch (f, w) {
            case (1, 2): info.symbol = r.string()
            case (3, 2): info.documentation.append(r.string())
            case (4, 2):
                var rel = r.lengthDelimited()
                var x = SCIPRelationship(symbol: "", isReference: false, isImplementation: false, isTypeDefinition: false)
                while !rel.atEnd {
                    let (rf, rw) = rel.tag()
                    switch (rf, rw) {
                    case (1, 2): x.symbol = rel.string()
                    case (2, 0): x.isReference = rel.varint() != 0
                    case (3, 0): x.isImplementation = rel.varint() != 0
                    case (4, 0): x.isTypeDefinition = rel.varint() != 0
                    default: rel.skip(rw)
                    }
                }
                info.relationships.append(x)
            case (5, 0): info.kind = Int(r.varint())
            case (6, 2): info.displayName = r.string()
            default: r.skip(w)
            }
        }
        return info
    }

    // MARK: Queries

    func occurrence(path: String, line: Int, col: Int) -> SCIPOccurrence? {
        guard let doc = documents[path] else { return nil }
        return doc.occurrences
            .filter { $0.line == line && $0.startCol <= col && col <= $0.endCol }
            .min { ($0.endCol - $0.startCol) < ($1.endCol - $1.startCol) }
    }

    func occurrences(of symbol: String) -> [(path: String, occ: SCIPOccurrence)] {
        (occurrencesBySymbol[symbol] ?? []).compactMap { e in
            documents[e.path].map { (e.path, $0.occurrences[e.index]) }
        }
    }

    func definitions(of symbol: String) -> [(path: String, occ: SCIPOccurrence)] {
        occurrences(of: symbol).filter { $0.occ.isDefinition }
    }

    static func displayName(_ symbol: String) -> String {
        // Descriptors end with one of `/ # . : ! ()` suffixes; take the last identifier.
        let trimmed = symbol.split(separator: " ").last.map(String.init) ?? symbol
        let parts = trimmed.split(whereSeparator: { "/#.:!()[]".contains($0) }).filter { !$0.isEmpty }
        return parts.last.map { String($0).replacingOccurrences(of: "`", with: "") } ?? symbol
    }

    static func isCallable(_ symbol: String) -> Bool { symbol.hasSuffix(").") }
}

/// Generates and loads a SCIP index for the workspace via `rust-analyzer scip`.
@MainActor @Observable
final class SCIPService {
    enum State: Equatable {
        case none, generating(String), loading, loaded, failed(String)
    }

    struct Meta: Codable {
        var generatedAt: Date
        /// When generation started; files modified after it may not match the index.
        var startedAt: Date?
        var revision: String
        var tool: String
        var documentCount: Int
    }

    let root: URL
    var state: State = .none
    var index: SCIPIndex?
    var meta: Meta?
    var uncoveredFiles: [String] = []
    private var generator: Process?

    init(root: URL) { self.root = root }

    var cacheURL: URL { AppPaths.support(for: root).appendingPathComponent("index.scip") }
    var metaURL: URL { AppPaths.support(for: root).appendingPathComponent("index.meta.json") }

    var summary: String {
        switch state {
        case .none: "No index"
        case .generating: "Indexing"
        case .loading: "Loading index"
        case .loaded: uncoveredFiles.isEmpty ? "Index complete" : "Index partial"
        case .failed: "Index failed"
        }
    }

    func loadCached(sourceFiles: [String]) {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        load(sourceFiles: sourceFiles)
    }

    private func load(sourceFiles: [String]) {
        state = .loading
        let url = cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                await MainActor.run { self.state = .failed("could not read cache") }
                return
            }
            let idx = SCIPIndex(data: data)
            let covered = Set(idx.documents.keys)
            let uncovered = sourceFiles.filter { $0.hasSuffix(".rs") && !covered.contains($0) }
            await MainActor.run {
                self.index = idx
                self.uncoveredFiles = uncovered
                self.state = .loaded
            }
        }
    }

    func generate(revision: String, sourceFiles: [String]) {
        state = .generating("Locating rust-analyzer")
        Task {
            let bin = await RustAnalyzer.resolveBinary()
            self.runGenerator(bin, revision: revision, sourceFiles: sourceFiles)
        }
    }

    private func runGenerator(_ bin: String?, revision: String, sourceFiles: [String]) {
        guard let bin else {
            state = .failed("rust-analyzer not found")
            return
        }
        generator?.terminate()
        state = .generating("Running rust-analyzer scip")
        runGeneration += 1
        let gen = runGeneration
        let startedAt = Date()
        let tmp = cacheURL.deletingLastPathComponent().appendingPathComponent("index-\(gen)-\(UUID().uuidString.prefix(8)).scip.tmp")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["scip", root.path, "--output", tmp.path]
        p.currentDirectoryURL = root
        p.environment = Shell.environment
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        let tail = LockedData()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            tail.append(d)
            let line = String(decoding: d, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            Task { @MainActor in
                if case .generating = self?.state, !line.isEmpty { self?.state = .generating(String(line.prefix(80))) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            errPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            let errTail = String(decoding: tail.data.suffix(400), as: UTF8.self)
            Task { @MainActor in
                // A run that has been replaced must not overwrite the newer one's state.
                guard let self, self.runGeneration == gen else { try? FileManager.default.removeItem(at: tmp); return }
                self.generator = nil
                guard status == 0 else {
                    self.state = .failed("rust-analyzer scip exited \(status): \(errTail.split(separator: "\n").last ?? "")")
                    return
                }
                try? FileManager.default.removeItem(at: self.cacheURL)
                try? FileManager.default.moveItem(at: tmp, to: self.cacheURL)
                self.meta = Meta(generatedAt: Date(), startedAt: startedAt, revision: revision, tool: "rust-analyzer scip", documentCount: 0)
                self.load(sourceFiles: sourceFiles)
                Task { @MainActor in
                    while self.state == .loading { try? await Task.sleep(nanoseconds: 100_000_000) }
                    if let idx = self.index {
                        self.meta?.documentCount = idx.documents.count
                        self.meta?.tool = "\(idx.toolName) \(idx.toolVersion)".trimmingCharacters(in: .whitespaces)
                    }
                    if let m = self.meta, let d = try? JSONEncoder().encode(m) { try? d.write(to: self.metaURL) }
                }
            }
        }
        do { try p.run(); generator = p } catch { state = .failed(error.localizedDescription) }
    }

    private var runGeneration = 0
    private var staleCache: [String: (checked: Date, stale: Bool)] = [:]

    /// Whether a file changed after the index was generated, so the index's positions may not match
    /// its text. Checked by modification time, at most every few seconds per file.
    func isStale(_ path: String) -> Bool {
        guard let started = meta?.startedAt ?? meta?.generatedAt else { return false }
        if let c = staleCache[path], Date().timeIntervalSince(c.checked) < 5 { return c.stale }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.modificationDate] as? Date) ?? .distantPast
        let stale = mtime > started
        staleCache[path] = (Date(), stale)
        return stale
    }

    func cancel() {
        generator?.terminate()
        generator = nil
        state = index == nil ? .none : .loaded
    }
}
