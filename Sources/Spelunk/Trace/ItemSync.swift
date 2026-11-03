import Foundation

/// Keeps a list of identifiable values in the store's `items` table: loads it (importing a legacy
/// JSON file once) and writes only rows that changed, in order, off the main thread.
@MainActor
final class ItemSync<T: Codable & Identifiable> where T.ID == UUID {
    let kind: String
    private let store: Store
    private let legacy: URL
    private var written: [UUID: (Data, Double)] = [:]
    private var chain: Task<Void, Never>?

    init(kind: String, root: URL, legacyFile: String) {
        self.kind = kind
        store = Store.shared(for: root)
        legacy = AppPaths.support(for: root).appendingPathComponent(legacyFile)
    }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    func load() async -> [T] {
        var rows = await store.items(kind)
        if rows.isEmpty, let d = try? Data(contentsOf: legacy) {
            let old = (try? Self.decoder.decode([T].self, from: d)) ?? (try? JSONDecoder().decode([T].self, from: d)) ?? []
            if !old.isEmpty {
                sync(old)
                await chain?.value
                rows = await store.items(kind)
            }
            try? FileManager.default.moveItem(at: legacy, to: legacy.appendingPathExtension("imported"))
        }
        let values = rows.compactMap { try? Self.decoder.decode(T.self, from: $0) }
        for (i, v) in values.enumerated() { if let e = try? Self.encoder.encode(v) { written[v.id] = (e, Double(i)) } }
        return values
    }

    func sync(_ values: [T]) {
        var upsert: [(id: String, value: Data, position: Double)] = []
        var seen: Set<UUID> = []
        for (i, v) in values.enumerated() {
            seen.insert(v.id)
            guard let e = try? Self.encoder.encode(v) else { continue }
            if let w = written[v.id], w.0 == e, w.1 == Double(i) { continue }
            written[v.id] = (e, Double(i))
            upsert.append((v.id.uuidString, e, Double(i)))
        }
        let removed = written.keys.filter { !seen.contains($0) }
        for r in removed { written[r] = nil }
        guard !upsert.isEmpty || !removed.isEmpty else { return }
        let store = self.store, kind = self.kind, previous = chain
        let delete = removed.map(\.uuidString)
        chain = Task.detached {
            await previous?.value
            await store.syncItems(kind, upsert: upsert, delete: delete)
        }
    }

    /// Waits for pending writes, for shutdown.
    func flush() async { await chain?.value }
}
