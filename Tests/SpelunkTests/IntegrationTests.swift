import XCTest
@testable import Spelunk

/// Runs against a real Cargo workspace when SPELUNK_IT_REPO is set.
final class IntegrationTests: XCTestCase {
    var repo: URL? { ProcessInfo.processInfo.environment["SPELUNK_IT_REPO"].map { URL(fileURLWithPath: $0) } }

    func testSCIP() async throws {
        guard let repo else { throw XCTSkip("SPELUNK_IT_REPO not set") }
        guard let bin = await RustAnalyzer.resolveBinary() else { throw XCTSkip("no rust-analyzer") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("it-\(UUID()).scip")
        let r = try await Shell.run(bin, ["scip", repo.path, "--output", out.path], cwd: repo)
        XCTAssertTrue(r.ok, r.stderr.suffix(500).description)
        let idx = SCIPIndex(data: try Data(contentsOf: out))
        XCTAssertFalse(idx.documents.isEmpty)
        print("SCIP: tool=\(idx.toolName) \(idx.toolVersion) docs=\(idx.documents.count) symbols=\(idx.occurrencesBySymbol.count) impls=\(idx.implementors.count) enc=\(idx.documents.values.first!.positionEncoding)")
        let callable = idx.occurrencesBySymbol.keys.first { SCIPIndex.isCallable($0) && !idx.definitions(of: $0).isEmpty }
        XCTAssertNotNil(callable)
        if let c = callable { print("sample callable: \(c) -> \(SCIPIndex.displayName(c)) refs=\(idx.occurrences(of: c).count)") }
    }

    @MainActor
    func testRustAnalyzer() async throws {
        guard let repo else { throw XCTSkip("SPELUNK_IT_REPO not set") }
        let ra = RustAnalyzer(root: repo)
        ra.start()
        let deadline = Date().addingTimeInterval(240)
        while ra.status != .ready && Date() < deadline {
            if case .failed(let e) = ra.status { XCTFail(e); return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        print("RA status: \(ra.status) version=\(ra.version ?? "?")")
        let docs = DocumentCache(root: repo)
        let files = await VCS.listFiles(repo, vcs: .git).filter { $0.hasSuffix(".rs") }
        var checked = 0
        for f in files.prefix(20) {
            guard let doc = docs.document(f) else { continue }
            ra.didOpen(path: f, text: doc.text, language: .rust)
            // Find a call token and resolve it.
            guard let call = doc.syntax.tokens.first(where: { $0.kind == .function }) else { continue }
            let pos = doc.lines.position(of: call.range.location)
            let defs = try await ra.definition(path: f, at: pos)
            let refs = try await ra.references(path: f, at: pos)
            let items = try await ra.prepareCallHierarchy(path: f, at: pos)
            var callers = 0
            if let i = items.first { callers = try await ra.calls(.incoming, of: i).count }
            print("\(f):\(pos.line + 1) \(doc.ns.substring(with: call.range)) defs=\(defs.map(\.shortDescription)) refs=\(refs.count) callers=\(callers)")
            XCTAssertFalse(defs.isEmpty)
            checked += 1
            if checked >= 3 { break }
        }
        XCTAssertGreaterThan(checked, 0)
        let hub = IntelHub(root: repo, ra: ra, scip: SCIPService(root: repo), docs: docs)
        if let f = files.first, let doc = docs.document(f), let t = doc.syntax.tokens.first(where: { $0.kind == .function }) {
            let p = doc.lines.position(of: t.range.location)
            let d = await hub.details(path: f, at: p, name: doc.ns.substring(with: t.range))
            print("details: \(d.name) \(d.kindLabel) \(d.signature ?? "-") via \(d.source)")
        }
        ra.stop()
    }
}
