import CoreServices
import Foundation

/// Recursive FSEvents watch on a repository, reporting changed repo-relative paths in batches.
/// VCS metadata and build output are ignored, so jj or cargo writing there never triggers a refresh.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let root: URL
    private let onChange: @Sendable ([String]) -> Void
    private static let ignoredComponents: Set<String> = [".git", ".jj", "target", "node_modules", ".build", "dist"]

    init(root: URL, onChange: @escaping @Sendable ([String]) -> Void) {
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
        let relevant = absolute.compactMap { p -> String? in
            guard let prefix = prefixes.first(where: { p.hasPrefix($0) }) else { return nil }
            let rel = String(p.dropFirst(prefix.count))
            if rel.split(separator: "/").contains(where: { Self.ignoredComponents.contains(String($0)) }) { return nil }
            return rel
        }
        if !relevant.isEmpty { onChange(relevant) }
    }
}
