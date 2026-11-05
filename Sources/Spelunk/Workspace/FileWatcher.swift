import CoreServices
import Foundation

/// Recursive FSEvents watch on a repository, reporting changed repo-relative paths in batches.
/// VCS metadata and build output are left out of the paths, so jj or cargo writing there never
/// reports a file; a batch notes instead whether history may have moved (a jj operation, or a git
/// HEAD or ref update).
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let onChange: @Sendable (_ paths: [String], _ historyMoved: Bool) -> Void
    private static let ignoredComponents: Set<String> = [".git", ".jj", "target", "node_modules", ".build", "dist"]

    init(root: URL, onChange: @escaping @Sendable (_ paths: [String], _ historyMoved: Bool) -> Void) {
        self.root = root.standardizedFileURL
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.handle(Array(array.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "spelunk.fswatch"))
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }

    /// The root as given and with symlinks resolved; FSEvents reports the resolved path (a repository
    /// under /tmp arrives as /private/tmp).
    private lazy var prefixes: [String] = {
        var out = [root.path + "/"]
        if let real = realpath(root.path, nil) {
            let r = String(cString: real) + "/"
            free(real)
            if r != out[0] { out.append(r) }
        }
        return out
    }()

    private func handle(_ absolute: [String]) {
        let prefixes = self.prefixes
        var historyMoved = false
        let relevant = absolute.compactMap { p -> String? in
            guard let prefix = prefixes.first(where: { p.hasPrefix($0) }) else { return nil }
            let rel = String(p.dropFirst(prefix.count))
            if rel.hasPrefix(".jj/repo/op_heads/") || rel == ".git/HEAD" || rel.hasPrefix(".git/refs/heads/") { historyMoved = true }
            if rel.split(separator: "/").contains(where: { Self.ignoredComponents.contains(String($0)) }) { return nil }
            return rel
        }
        if !relevant.isEmpty || historyMoved { onChange(relevant, historyMoved) }
    }
}
