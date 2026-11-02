import Foundation
import Observation

enum VCSKind: String, Sendable { case jj, git, none }

struct VCSInfo: Sendable {
    var kind: VCSKind
    var revision: String
    var description: String
    var hasGit: Bool
    /// Why a VCS that appears to be present could not be used.
    var problem: String?
}

enum VCS {
    static func detect(_ root: URL) async -> VCSInfo {
        let fm = FileManager.default
        let hasJJ = fm.fileExists(atPath: root.appendingPathComponent(".jj").path)
        let hasGit = fm.fileExists(atPath: root.appendingPathComponent(".git").path)
        var problem: String?
        if hasJJ {
            let r = try? await Shell.run("jj", ["log", "--no-graph", "--ignore-working-copy", "-r", "@", "-T", "commit_id.short() ++ \"\\t\" ++ description.first_line()"], cwd: root)
            if let r, r.ok {
                let parts = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 1)
                return VCSInfo(kind: .jj, revision: parts.first.map(String.init) ?? "", description: parts.count > 1 ? String(parts[1]) : "", hasGit: hasGit)
            }
            let err = r?.stderr.split(separator: "\n").first.map(String.init) ?? "jj not available"
            problem = "jj: \(err)"
        }
        if hasGit, let out = try? await Shell.output("git", ["log", "-1", "--format=%h\t%s"], cwd: root) {
            let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 1)
            return VCSInfo(kind: .git, revision: parts.first.map(String.init) ?? "", description: parts.count > 1 ? String(parts[1]) : "", hasGit: true, problem: problem)
        }
        return VCSInfo(kind: .none, revision: "", description: "", hasGit: false, problem: problem)
    }

    static func listFiles(_ root: URL, vcs: VCSKind) async -> [String] {
        if vcs == .jj, let out = try? await Shell.output("jj", ["file", "list", "--ignore-working-copy"], cwd: root) {
            return out.split(separator: "\n").map(String.init)
        }
        if vcs == .git, let out = try? await Shell.output("git", ["ls-files", "--cached", "--others", "--exclude-standard"], cwd: root) {
            return out.split(separator: "\n").map(String.init)
        }
        // Outside a usable repository: ripgrep honours .gitignore files without git and lists far
        // faster than a FileManager walk.
        if Shell.which("rg") != nil,
           let out = try? await Shell.output("rg", ["--files", "--no-require-git", "--hidden", "-g", "!.git", "-g", "!.jj", "-g", "!target"], cwd: root) {
            return out.split(separator: "\n").map(String.init).sorted()
        }
        return await Task.detached(priority: .userInitiated) { walk(root) }.value
    }

    private static func walk(_ root: URL) -> [String] {
        let skip: Set<String> = [".git", ".jj", "target", "node_modules", ".build", "build", "dist"]
        var out: [String] = []
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let u = e?.nextObject() as? URL {
            if skip.contains(u.lastPathComponent) { e?.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out.append(u.relativePath(from: root))
            if out.count > 200_000 { break }
        }
        return out.sorted()
    }

    /// Immediate subdirectories that are repositories, for when the opened folder is not one.
    static func childRepositories(_ root: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { u in
            fm.fileExists(atPath: u.appendingPathComponent(".git").path) || fm.fileExists(atPath: u.appendingPathComponent(".jj").path)
        }
    }
}

final class FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    var children: [FileNode]?
    var isDirectory: Bool { children != nil }

    init(name: String, path: String, children: [FileNode]?) {
        self.id = path; self.name = name; self.path = path; self.children = children
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static func build(_ paths: [String]) -> FileNode {
        final class Builder {
            var dirs: [String: Builder] = [:]
            var files: [String] = []
        }
        let root = Builder()
        for p in paths {
            var node = root
            let comps = p.split(separator: "/").map(String.init)
            for c in comps.dropLast() {
                if let n = node.dirs[c] { node = n } else { let n = Builder(); node.dirs[c] = n; node = n }
            }
            if let last = comps.last { node.files.append(last) }
        }
        func make(_ b: Builder, name: String, path: String) -> FileNode {
            let dirs = b.dirs.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { d in
                make(b.dirs[d]!, name: d, path: path.isEmpty ? d : "\(path)/\(d)")
            }
            let files = b.files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { f in
                FileNode(name: f, path: path.isEmpty ? f : "\(path)/\(f)", children: nil)
            }
            return FileNode(name: name, path: path, children: dirs + files)
        }
        return make(root, name: "", path: "")
    }
}

enum FileClassifier {
    static let sourceExtensions: Set<String> = [
        "rs", "toml", "md", "swift", "c", "h", "cc", "cpp", "hpp", "go", "py", "js", "ts", "tsx", "jsx", "proto",
        "sql", "sh", "yml", "yaml", "json", "lock", "slt", "td", "txt",
    ]

    static func isSource(_ path: String) -> Bool {
        let ext = path.pathExtension.lowercased()
        if ext.isEmpty { return ["Makefile", "Dockerfile", "BUILD", "WORKSPACE"].contains(path.lastPathComponent) }
        return sourceExtensions.contains(ext)
    }

    static func isTest(_ path: String) -> Bool {
        let comps = path.split(separator: "/")
        if comps.contains(where: { $0 == "tests" || $0 == "benches" || $0 == "test" || $0 == "testdata" || $0 == "fixtures" }) { return true }
        let name = path.lastPathComponent
        return name.hasSuffix("_test.rs") || name.hasSuffix("_tests.rs") || name == "tests.rs" || name.hasSuffix(".snap")
            || name.hasSuffix(".slt") || name.hasSuffix(".td")
    }

    static func isGenerated(_ path: String) -> Bool {
        let name = path.lastPathComponent
        return name == "Cargo.lock" || name.hasSuffix(".snap") || name.hasSuffix(".pb.rs") || name.hasSuffix(".generated.rs")
            || path.contains("/generated/") || path.hasPrefix("vendor/") || path.contains("/vendor/")
            || name == "package-lock.json" || name == "yarn.lock" || name == "pnpm-lock.yaml"
    }
}

/// A loaded file: text, line table, and syntax.
final class SourceDocument: Identifiable {
    let id = UUID()
    let path: String
    let text: String
    let ns: NSString
    let lines: LineIndex
    let language: SourceLanguage
    let syntax: SyntaxInfo
    let languageName: String
    /// Nil when this is the on-disk working copy; otherwise a label such as "Before @-".
    let revisionLabel: String?

    init(path: String, text: String, revisionLabel: String? = nil) {
        self.path = path
        self.text = text
        self.ns = text as NSString
        self.lines = LineIndex(ns)
        self.language = SourceLanguage.from(path: path)
        self.syntax = SyntaxAnalyzer.analyze(text, language: language, path: path)
        self.languageName = language == .rust ? "Rust" : (GrammarRegistry.shared.grammar(forPath: path)?.spec.displayName ?? language.displayName)
        self.revisionLabel = revisionLabel
    }

    func lineText(_ line: Int) -> String { ns.line(lines, line) }

    func word(at p: SourcePos) -> (String, SourceRange)? {
        let off = lines.offset(of: p)
        guard let r = ns.identifierRange(at: off) else { return nil }
        let s = lines.position(of: r.location), e = lines.position(of: NSMaxRange(r))
        return (ns.substring(with: r), SourceRange(start: s, end: e))
    }
}

/// Cache of parsed documents keyed by path; shared by navigation, review and providers.
@MainActor
final class DocumentCache {
    let root: URL
    private var cache: [String: (Date, SourceDocument)] = [:]

    init(root: URL) { self.root = root }

    func url(for path: String) -> URL { path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path) }

    func document(_ path: String) -> SourceDocument? {
        let u = url(for: path)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast
        if let (t, d) = cache[path], t == mtime { return d }
        guard let data = try? Data(contentsOf: u), data.count < 8_000_000 else { return nil }
        let doc = SourceDocument(path: path, text: String(decoding: data, as: UTF8.self))
        cache[path] = (mtime, doc)
        if cache.count > 300 { cache.removeAll() }
        return doc
    }

    func invalidate() { cache.removeAll() }
}
