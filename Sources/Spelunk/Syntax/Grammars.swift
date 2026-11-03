import Foundation
import SwiftTreeSitter

/// A user-installed tree-sitter grammar: a compiled parser plus highlight and tag queries.
struct GrammarSpec: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var displayName: String
    var extensions: [String]
    var repository: String
    var subdirectory: String?
    var revision: String?
    /// Other installed grammars whose highlight queries are prepended (e.g. typescript inherits javascript).
    var inherits: [String] = []
    var installedAt = Date()
    var id: String { name }
    var symbol: String { "tree_sitter_" + name.replacingOccurrences(of: "-", with: "_") }
}

final class LoadedGrammar: @unchecked Sendable {
    let spec: GrammarSpec
    let directory: URL
    var language: SwiftTreeSitter.Language?
    var highlights: Query?
    var tags: Query?
    var error: String?

    init(spec: GrammarSpec, directory: URL) { self.spec = spec; self.directory = directory }

    var dylib: URL { directory.appendingPathComponent("lib\(spec.name).dylib") }
    var highlightsURL: URL { directory.appendingPathComponent("highlights.scm") }
    var tagsURL: URL { directory.appendingPathComponent("tags.scm") }
}

/// Discovers, installs and loads grammars from `~/Library/Application Support/Spelunk/grammars`.
final class GrammarRegistry: @unchecked Sendable {
    static let shared = GrammarRegistry()

    let directory: URL
    private let lock = NSLock()
    private var byName: [String: LoadedGrammar] = [:]
    private var byExtension: [String: LoadedGrammar] = [:]
    private var handles: [String: UnsafeMutableRawPointer] = [:]

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spelunk/grammars", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    var all: [LoadedGrammar] {
        lock.lock(); defer { lock.unlock() }
        return byName.values.sorted { $0.spec.name < $1.spec.name }
    }

    func grammar(forPath path: String) -> LoadedGrammar? {
        let ext = path.pathExtension.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let g = byExtension[ext.isEmpty ? path.lastPathComponent : ext], g.language != nil { return g }
        return nil
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [String: LoadedGrammar] = [:]
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("grammar.json")),
                  let spec = try? JSONDecoder().decode(GrammarSpec.self, from: data) else { continue }
            loaded[spec.name] = LoadedGrammar(spec: spec, directory: d)
        }
        for g in loaded.values { load(g, all: loaded) }
        var exts: [String: LoadedGrammar] = [:]
        // Only grammars that actually loaded may claim extensions.
        for g in loaded.values.sorted(by: { $0.spec.name < $1.spec.name }) where g.language != nil {
            for e in g.spec.extensions { exts[e.lowercased()] = g }
        }
        lock.lock()
        byName = loaded
        byExtension = exts
        lock.unlock()
    }

    private func load(_ g: LoadedGrammar, all: [String: LoadedGrammar]) {
        let path = g.dylib.path
        let handle: UnsafeMutableRawPointer
        if let h = handles[path] { handle = h } else {
            guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                g.error = "dlopen failed: \(String(cString: dlerror()))"
                return
            }
            handles[path] = h
            handle = h
        }
        guard let sym = dlsym(handle, g.spec.symbol) else {
            g.error = "symbol \(g.spec.symbol) not found in \(g.dylib.lastPathComponent)"
            return
        }
        typealias Fn = @convention(c) () -> OpaquePointer
        let lang = SwiftTreeSitter.Language(language: unsafeBitCast(sym, to: Fn.self)())
        let abi = lang.ABIVersion
        guard abi >= SwiftTreeSitter.Language.minimumCompatibleVersion && abi <= SwiftTreeSitter.Language.version else {
            g.error = "grammar ABI \(abi) is outside the supported range \(SwiftTreeSitter.Language.minimumCompatibleVersion)–\(SwiftTreeSitter.Language.version)"
            return
        }
        g.language = lang
        var highlightSource = ""
        for parent in g.spec.inherits {
            if let p = all[parent], let s = try? String(contentsOf: p.highlightsURL, encoding: .utf8) { highlightSource += s + "\n" }
        }
        if let s = try? String(contentsOf: g.highlightsURL, encoding: .utf8) { highlightSource += s }
        if !highlightSource.isEmpty {
            do { g.highlights = try Query(language: lang, data: Data(highlightSource.utf8)) } catch {
                g.error = "highlights.scm: \(error)"
            }
        }
        if let s = try? String(contentsOf: g.tagsURL, encoding: .utf8) {
            g.tags = try? Query(language: lang, data: Data(s.utf8))
        }
    }

    func remove(_ name: String) {
        lock.lock()
        let g = byName[name]
        lock.unlock()
        if let g { try? FileManager.default.removeItem(at: g.directory) }
        reload()
    }

    // MARK: Installation

    struct Preset: Identifiable {
        var id: String { url + (subdirectory ?? "") }
        var label: String
        var url: String
        var subdirectory: String? = nil
        /// A branch or tag; some grammars publish generated sources only on a separate branch.
        var revision: String? = nil
    }

    static let presets: [Preset] = [
        Preset(label: "Swift", url: "https://github.com/alex-pinkus/tree-sitter-swift", revision: "with-generated-files"),
        Preset(label: "Python", url: "https://github.com/tree-sitter/tree-sitter-python"),
        Preset(label: "Go", url: "https://github.com/tree-sitter/tree-sitter-go"),
        Preset(label: "JavaScript", url: "https://github.com/tree-sitter/tree-sitter-javascript"),
        Preset(label: "TypeScript + TSX", url: "https://github.com/tree-sitter/tree-sitter-typescript"),
        Preset(label: "C", url: "https://github.com/tree-sitter/tree-sitter-c"),
        Preset(label: "C++", url: "https://github.com/tree-sitter/tree-sitter-cpp"),
        Preset(label: "Java", url: "https://github.com/tree-sitter/tree-sitter-java"),
        Preset(label: "JSON", url: "https://github.com/tree-sitter/tree-sitter-json"),
        Preset(label: "Bash", url: "https://github.com/tree-sitter/tree-sitter-bash"),
        Preset(label: "TOML", url: "https://github.com/tree-sitter-grammars/tree-sitter-toml"),
        Preset(label: "YAML", url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml"),
    ]

    struct InstallError: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Clones a grammar repository and builds every grammar it declares. Returns the installed specs.
    @discardableResult
    func install(url: String, subdirectory: String?, revision: String?, log: @escaping @Sendable (String) -> Void) async throws -> [GrammarSpec] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("spelunk-grammar-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        log("Cloning \(url)")
        var cloneArgs = ["clone", "--depth", "1", "--quiet"]
        if let revision, !revision.isEmpty { cloneArgs += ["--branch", revision] }
        let r = try await Shell.run("git", cloneArgs + ["--", url, work.path])
        guard r.ok else { throw InstallError(message: "git clone failed: \(r.stderr)") }

        var targets = discover(in: work, url: url)
        if let sub = subdirectory, !sub.isEmpty { targets = targets.filter { $0.subdirectory == sub } + (targets.contains { $0.subdirectory == sub } ? [] : [Self.fallbackSpec(url: url, subdirectory: sub)]) }
        guard !targets.isEmpty else { throw InstallError(message: "No grammar found in repository") }

        var installed: [GrammarSpec] = []
        for var spec in targets {
            spec.revision = revision
            let base = spec.subdirectory.map { work.appendingPathComponent($0) } ?? work
            let src = base.appendingPathComponent("src")
            guard fm.fileExists(atPath: src.appendingPathComponent("parser.c").path) else {
                throw InstallError(message: "\(spec.name): src/parser.c is missing; this repository does not commit generated parsers (run `tree-sitter generate` there first)")
            }
            let dest = directory.appendingPathComponent(spec.name, isDirectory: true)
            try? fm.removeItem(at: dest)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            log("Compiling \(spec.name)")
            try await compile(src: src, output: dest.appendingPathComponent("lib\(spec.name).dylib"), log: log)
            for (file, name) in [("highlights.scm", "highlights.scm"), ("tags.scm", "tags.scm")] {
                let candidates = [base.appendingPathComponent("queries/\(file)"), work.appendingPathComponent("queries/\(file)")]
                if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                    try? fm.copyItem(at: found, to: dest.appendingPathComponent(name))
                } else {
                    log("\(spec.name): no \(file)")
                }
            }
            let data = try JSONEncoder().encode(spec)
            try data.write(to: dest.appendingPathComponent("grammar.json"))
            installed.append(spec)
            log("Installed \(spec.displayName) for .\(spec.extensions.joined(separator: ", ."))")
        }
        reload()
        var ok: [GrammarSpec] = []
        for s in installed {
            if let g = all.first(where: { $0.spec.name == s.name }), let e = g.error {
                log("\(s.name): \(e)")
            } else {
                ok.append(s)
            }
        }
        return ok
    }

    private func compile(src: URL, output: URL, log: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        var objects: [String] = []
        var needsCxx = false
        let objDir = output.deletingLastPathComponent().appendingPathComponent("obj")
        try fm.createDirectory(at: objDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: objDir) }
        let sources = ["parser.c", "scanner.c", "scanner.cc", "scanner.cpp"].filter { fm.fileExists(atPath: src.appendingPathComponent($0).path) }
        for s in sources {
            let isCxx = s.hasSuffix(".cc") || s.hasSuffix(".cpp")
            needsCxx = needsCxx || isCxx
            let obj = objDir.appendingPathComponent(s + ".o").path
            let args = (isCxx ? ["-std=c++17"] : ["-std=c11"]) + ["-c", "-fPIC", "-O2", "-I", src.path, src.appendingPathComponent(s).path, "-o", obj]
            let r = try await Shell.run(isCxx ? "c++" : "cc", args)
            guard r.ok else { throw InstallError(message: "compiling \(s) failed:\n\(r.stderr.suffix(1500))") }
            objects.append(obj)
        }
        let r = try await Shell.run(needsCxx ? "c++" : "cc", ["-shared", "-o", output.path] + objects)
        guard r.ok else { throw InstallError(message: "linking failed:\n\(r.stderr.suffix(1500))") }
        log("Built \(output.lastPathComponent)")
    }

    /// Reads `tree-sitter.json` when present; otherwise infers one grammar from the repository name.
    private func discover(in repo: URL, url: String) -> [GrammarSpec] {
        let manifest = repo.appendingPathComponent("tree-sitter.json")
        if let data = try? Data(contentsOf: manifest),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let grammars = obj["grammars"] as? [[String: Any]], !grammars.isEmpty {
            // A manifest may list several names over one parser directory (tree-sitter-typescript's
            // "flow" reuses "tsx"); build each directory once.
            var seenPaths = Set<String>()
            return grammars.compactMap { g in
                guard let name = g["name"] as? String else { return nil }
                let path = (g["path"] as? String).flatMap { $0 == "." ? nil : $0 }
                guard seenPaths.insert(path ?? ".").inserted else { return nil }
                let types = (g["file-types"] as? [String]) ?? []
                // TypeScript-style grammars extend JavaScript's highlights by convention.
                var inherits: [String] = []
                if name == "typescript" || name == "tsx" { inherits = ["javascript"] }
                if name == "cpp" { inherits = ["c"] }
                return GrammarSpec(name: name, displayName: (g["camelcase"] as? String) ?? (g["title"] as? String) ?? name.capitalized,
                                   extensions: types, repository: url, subdirectory: path, inherits: inherits)
            }
        }
        return [Self.fallbackSpec(url: url, subdirectory: nil)]
    }

    static func fallbackSpec(url: String, subdirectory: String?) -> GrammarSpec {
        var name = (subdirectory?.split(separator: "/").last.map(String.init)) ?? url.split(separator: "/").last.map(String.init) ?? "grammar"
        name = name.replacingOccurrences(of: ".git", with: "").replacingOccurrences(of: "tree-sitter-", with: "")
        return GrammarSpec(name: name, displayName: name.capitalized, extensions: [name], repository: url, subdirectory: subdirectory)
    }
}

/// Highlighting and outline for documents parsed by an installed grammar.
enum DynamicSyntax {
    static func analyze(_ text: String, grammar g: LoadedGrammar) -> SyntaxInfo? {
        guard let lang = g.language else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(lang)) != nil, let tree = parser.parse(text), let root = tree.rootNode else { return nil }
        var info = SyntaxInfo()
        info.parsedWithTreeSitter = true
        info.errorCount = root.hasError ? 1 : 0
        let context = Predicate.Context(string: text)

        if let q = g.highlights {
            // First pattern wins for an identical range, matching tree-sitter-highlight's precedence.
            var best: [NSRange: (Int, TokenKind)] = [:]
            for match in q.execute(node: root, in: tree).resolve(with: context) {
                for c in match.captures {
                    guard let name = c.name, let kind = tokenKind(forCapture: name) else { continue }
                    if let existing = best[c.range], existing.0 <= match.patternIndex { continue }
                    best[c.range] = (match.patternIndex, kind)
                }
            }
            // Wider ranges first so nested captures are applied on top.
            info.tokens = best.map { Token(range: $0.key, kind: $0.value.1) }.sorted { $0.range.length > $1.range.length }
        }

        if let q = g.tags {
            let ns = text as NSString
            let index = LineIndex(ns)
            func srange(_ r: NSRange) -> SourceRange { SourceRange(start: index.position(of: r.location), end: index.position(of: NSMaxRange(r))) }
            var flat: [OutlineItem] = []
            for match in q.execute(node: root, in: tree).resolve(with: context) {
                guard let def = match.captures.first(where: { $0.name?.hasPrefix("definition.") == true }),
                      let nameCap = match.captures.first(where: { $0.name == "name" }) else { continue }
                let kindName = String(def.name!.dropFirst("definition.".count))
                let kind: OutlineKind = switch kindName {
                case "method": .method
                case "class": .classItem
                case "interface": .interface
                case "module": .module
                case "constant": .constant
                case "type": .typeAlias
                case "macro": .macro
                case "enum": .enumItem
                case "struct": .structItem
                default: .function
                }
                let full = srange(def.range)
                let detail = ns.substring(with: ns.lineRange(for: NSRange(location: def.range.location, length: 0)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                flat.append(OutlineItem(name: ns.substring(with: nameCap.range), kind: kind, range: full, nameRange: srange(nameCap.range),
                                        headerEndLine: full.start.line, detail: detail, isTest: false, isPublic: false))
            }
            info.outline = nest(flat)
        }
        return info
    }

    /// Builds a containment tree from flat, possibly unordered definitions.
    static func nest(_ items: [OutlineItem]) -> [OutlineItem] {
        let sorted = items.sorted { a, b in a.range.start != b.range.start ? a.range.start < b.range.start : a.range.end > b.range.end }
        var roots: [OutlineItem] = []
        var stack: [OutlineItem] = []
        for item in sorted {
            while let top = stack.last, !(top.range.start <= item.range.start && item.range.end <= top.range.end) { stack.removeLast() }
            if let parent = stack.last {
                item.parent = parent
                if item.kind == .function && (parent.kind == .classItem || parent.kind == .interface) { item.kind = .method }
                parent.children.append(item)
            } else {
                roots.append(item)
            }
            stack.append(item)
        }
        return roots
    }

    static func tokenKind(forCapture name: String) -> TokenKind? {
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "comment": return name.contains("doc") ? .docComment : .comment
        case "string", "character", "escape": return .string
        case "number", "float": return .number
        case "boolean": return .constant
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass", "conditional_operator": return .keyword
        case "function", "method":
            return name.contains("macro") ? .macro : (name.contains("builtin") ? .function : .function)
        case "constructor", "type": return .type
        case "property", "field": return .field
        case "attribute", "decorator", "annotation", "tag": return .attribute
        case "constant": return name.contains("builtin") ? .constant : .constant
        case "module", "namespace": return .module
        case "variable": return name.contains("builtin") ? .selfKeyword : (name.contains("parameter") ? nil : nil)
        case "operator": return .operatorToken
        case "label": return .lifetime
        case "embedded", "punctuation": return nil
        default: return nil
        }
    }
}
