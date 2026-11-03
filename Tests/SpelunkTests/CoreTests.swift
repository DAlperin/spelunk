import XCTest
@testable import Spelunk

final class SyntaxTests: XCTestCase {
    let src = """
    use std::sync::Mutex;

    /// Docs.
    pub struct Engine { inner: Mutex<u32> }

    impl Engine {
        pub fn new() -> Self { Engine { inner: Mutex::new(0) } }
        fn bump(&self) { *self.inner.lock().unwrap() += 1; }
    }

    trait Run { fn run(&self); }
    impl Run for Engine { fn run(&self) { self.bump() } }

    #[cfg(test)]
    mod tests {
        #[test]
        fn it_works() { assert!(true); }
    }
    """

    func testOutline() {
        let info = RustSyntax.analyze(src)
        XCTAssertTrue(info.parsedWithTreeSitter)
        XCTAssertEqual(info.errorCount, 0)
        let names = info.flatOutline.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertTrue(names.contains("structItem:Engine"), "\(names)")
        XCTAssertTrue(names.contains("method:bump"), "\(names)")
        XCTAssertTrue(names.contains("impl:Engine"), "\(names)")
        let bump = info.flatOutline.first { $0.name == "bump" }!
        XCTAssertEqual(bump.qualifiedName, "Engine::bump")
        XCTAssertTrue(info.flatOutline.first { $0.detail == "impl Run for Engine" } != nil)
        let testsMod = info.flatOutline.first { $0.name == "tests" }!
        XCTAssertTrue(testsMod.isTest)
        XCTAssertTrue(info.isTestLine(testsMod.range.start.line + 2))
        XCTAssertFalse(info.isTestLine(bump.range.start.line))
        XCTAssertEqual(info.enclosingItem(line: bump.range.start.line)?.name, "bump")
        XCTAssertTrue(info.tokens.contains { $0.kind == .docComment })
        XCTAssertTrue(info.tokens.contains { $0.kind == .keyword })
    }
}

final class DiffTests: XCTestCase {
    let diff = """
    diff --git a/src/lib.rs b/src/lib.rs
    index 111..222 100644
    --- a/src/lib.rs
    +++ b/src/lib.rs
    @@ -1,4 +1,5 @@ fn main
     fn a() {
    -    let x = 1;
    +    let x = 2;
    +    let y = 3;
    --- this is a removed line that looks like a header
     }
    diff --git a/Cargo.lock b/Cargo.lock
    --- a/Cargo.lock
    +++ b/Cargo.lock
    @@ -10,1 +10,1 @@
    -version = "1"
    +version = "2"
    diff --git a/new.rs b/new.rs
    new file mode 100644
    --- /dev/null
    +++ b/new.rs
    @@ -0,0 +1,2 @@
    +fn f() {}
    +fn g() {}
    """

    func testParse() {
        let files = DiffParser.parse(diff)
        XCTAssertEqual(files.map(\.path), ["src/lib.rs", "Cargo.lock", "new.rs"])
        let h = files[0].hunks[0]
        XCTAssertEqual(h.addedCount, 2)
        XCTAssertEqual(h.removedCount, 2)
        XCTAssertEqual(h.added.first?.newLine, 1)
        XCTAssertEqual(h.removed.first?.oldLine, 1)
        XCTAssertEqual(h.header, "fn main")
        XCTAssertEqual(files[2].status, .added)
        XCTAssertEqual(files[2].hunks[0].addedCount, 2)
    }
}

final class ClassifierTests: XCTestCase {
    func hunk(_ removed: [String], _ added: [String], path: String = "src/x.rs") -> (FileDiff, Hunk) {
        var lines: [DiffLine] = []
        for (i, r) in removed.enumerated() { lines.append(DiffLine(kind: .removed, text: r, oldLine: i, newLine: nil)) }
        for (i, a) in added.enumerated() { lines.append(DiffLine(kind: .added, text: a, oldLine: nil, newLine: i)) }
        let h = Hunk(id: "\(path)#0", path: path, oldStart: 1, oldCount: removed.count, newStart: 1, newCount: added.count, header: "", lines: lines)
        return (FileDiff(oldPath: path, newPath: path, status: .modified, hunks: [h]), h)
    }

    func tier(_ removed: [String], _ added: [String], path: String = "src/x.rs") -> HunkAnalysis {
        let (f, h) = hunk(removed, added, path: path)
        return ChangeClassifier.classify(file: f, hunk: h, oldDoc: nil, newDoc: nil)
    }

    func testFormatting() {
        XCTAssertEqual(tier(["let x = foo(a,b);"], ["let x = foo(", "    a,", "    b", ");"]).tier, .mechanical)
        XCTAssertNotEqual(tier(["foo(a)"], ["bar(a)"]).tier, .mechanical) // call target swap is not a rename
    }

    func testComments() {
        let typo = tier(["// old comment", "let x = 1;"], ["// new comment", "let x = 1;"])
        XCTAssertEqual(typo.tier, .mechanical)
        XCTAssertEqual(typo.reasons, ["comment wording"])

        let rewritten = tier(["/// Returns the value.", "fn f() {}"],
                             ["/// Returns the cached value, recomputing it when the epoch advanced past the snapshot.", "fn f() {}"])
        XCTAssertEqual(rewritten.tier, .docs)
        XCTAssertEqual(rewritten.reasons, ["doc comments"])

        let added = tier(["let x = 1;"], ["// Readers rely on this ordering being stable across restarts.", "let x = 1;"])
        XCTAssertEqual(added.tier, .docs)

        let safety = tier(["// SAFETY: the pointer is valid for the lifetime of the guard.", "unsafe { p.read() }"],
                          ["// SAFETY: the pointer is valid while the lock is held.", "unsafe { p.read() }"])
        XCTAssertEqual(safety.tier, .critical)

        XCTAssertEqual(tier(["let x = 1;"], ["let  x = 1;"]).tier, .mechanical)
    }

    func testImports() {
        XCTAssertEqual(tier(["use std::sync::Arc;"], ["use std::sync::{Arc, Mutex};"]).tier, .mechanical)
    }

    func testRename() {
        let a = tier(["let count = items.len();", "total += count;"], ["let n = items.len();", "total += n;"])
        XCTAssertEqual(a.tier, .mechanical)
        XCTAssertTrue(a.reasons[0].hasPrefix("rename"))
    }

    func testCritical() {
        XCTAssertEqual(tier(["let v = m.get(k)?;"], ["let v = m.get(k).unwrap();"]).tier, .critical)
        XCTAssertEqual(tier([], ["unsafe { ptr.read() }"]).tier, .critical)
        XCTAssertEqual(tier(["x.load(Ordering::Relaxed)"], ["x.load(Ordering::SeqCst)"]).tier, .critical)
        // Prose mentioning unsafe inside a string is not a signal.
        XCTAssertNotEqual(tier([], [#"let msg = "this is unsafe";"#]).tier, .critical)
    }

    func testFiles() {
        XCTAssertEqual(tier(["a"], ["b"], path: "Cargo.lock").tier, .mechanical)
        XCTAssertEqual(tier(["a"], ["b"], path: "crate/tests/foo.rs").tier, .tests)
        XCTAssertEqual(tier(["x"], ["y"], path: "README.md").tier, .docs)
    }

    func testBehaviorAndPlumbing() {
        XCTAssertEqual(tier(["if a > b { return 1; }"], ["if a >= b { return 1; }"]).tier, .behavior)
        XCTAssertEqual(tier(["Foo::new(a, b)"], ["Foo::new(a, b, config.clone())"]).tier, .supporting)
    }

    func testTestRegionWithDocs() {
        let old = SourceDocument(path: "src/x.rs", text: "fn a() {}\n#[cfg(test)]\nmod tests {\n    fn t() { let x = 1; }\n}\n")
        let new = SourceDocument(path: "src/x.rs", text: "fn a() {}\n#[cfg(test)]\nmod tests {\n    fn t() { let x = 2; }\n}\n")
        let lines = [DiffLine(kind: .removed, text: "    fn t() { let x = 1; }", oldLine: 3, newLine: nil),
                     DiffLine(kind: .added, text: "    fn t() { let x = 2; }", oldLine: nil, newLine: 3)]
        let h = Hunk(id: "x#0", path: "src/x.rs", oldStart: 4, oldCount: 1, newStart: 4, newCount: 1, header: "", lines: lines)
        let f = FileDiff(oldPath: "src/x.rs", newPath: "src/x.rs", status: .modified, hunks: [h])
        XCTAssertEqual(ChangeClassifier.classify(file: f, hunk: h, oldDoc: old, newDoc: new).tier, .tests)
    }

    func testPublicAPI() {
        let old = SourceDocument(path: "src/x.rs", text: "pub fn a(x: u32) -> u32 {\n    x\n}\n")
        let new = SourceDocument(path: "src/x.rs", text: "pub fn a(x: u64) -> u64 {\n    x\n}\n")
        let lines = [DiffLine(kind: .removed, text: "pub fn a(x: u32) -> u32 {", oldLine: 0, newLine: nil),
                     DiffLine(kind: .added, text: "pub fn a(x: u64) -> u64 {", oldLine: nil, newLine: 0)]
        let h = Hunk(id: "x#0", path: "src/x.rs", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "", lines: lines)
        let f = FileDiff(oldPath: "src/x.rs", newPath: "src/x.rs", status: .modified, hunks: [h])
        let a = ChangeClassifier.classify(file: f, hunk: h, oldDoc: old, newDoc: new)
        XCTAssertEqual(a.tier, .critical)
        XCTAssertTrue(a.reasons.contains("public API: a"), "\(a.reasons)")
    }
}

final class TextTests: XCTestCase {
    func testLineIndex() {
        let ns = "ab\ncdé\n\nx" as NSString
        let idx = LineIndex(ns)
        XCTAssertEqual(idx.lineCount, 4)
        XCTAssertEqual(idx.position(of: 4), SourcePos(line: 1, col: 1))
        XCTAssertEqual(idx.offset(of: SourcePos(line: 3, col: 0)), 8)
        XCTAssertEqual(ColumnEncoding.utf8ToUTF16("cdé x", 5), 4)
    }

    func testFuzzy() {
        XCTAssertNotNil(Fuzzy.score("agtr", "modules/agent/agent_tree.rs"))
        XCTAssertNil(Fuzzy.score("zzz", "src/lib.rs"))
        XCTAssertGreaterThan(Fuzzy.score("lib", "src/lib.rs")!, Fuzzy.score("lib", "src/a/l/i/b/x.rs")!)
    }
}

final class FuzzyPaletteTests: XCTestCase {
    func testCommandFiltering() {
        XCTAssertNil(Fuzzy.score("revi", "go to file… "))
        XCTAssertNotNil(Fuzzy.score("revi", "review working copy jj @- → @"))
        XCTAssertGreaterThan(Fuzzy.score("ctrl inst", "src/compute-client/src/controller/instance.rs")!,
                             Fuzzy.score("ctrl inst", "src/transform/src/literal_constraints.rs") ?? 0)
    }
}

final class RepoFilterTests: XCTestCase {
    func testFiltersChildRepositories() {
        let repos = ["materialize", "iceberg-rust", "differential-dataflow", "timely-dataflow", "aj"].map { URL(fileURLWithPath: "/w/\($0)") }
        XCTAssertEqual(NotARepoView.filtered(repos, "").map(\.lastPathComponent).first, "aj")
        let dd = NotARepoView.filtered(repos, "dd").map(\.lastPathComponent)
        XCTAssertEqual(dd.first, "differential-dataflow")
        XCTAssertFalse(dd.contains("aj"))
        XCTAssertEqual(NotARepoView.filtered(repos, "mz").count, 1)
    }
}

final class GroupingTests: XCTestCase {
    func testRemovedFlagGroupsAcrossFiles() {
        let diff = """
        diff --git a/src/a.rs b/src/a.rs
        --- a/src/a.rs
        +++ b/src/a.rs
        @@ -1,3 +1,2 @@
         fn a() {
        -    if ENABLE_HALF_JOIN2.get(cfg) { half_join2() }
             other();
        diff --git a/src/b.rs b/src/b.rs
        --- a/src/b.rs
        +++ b/src/b.rs
        @@ -1,3 +1,1 @@
        -pub const ENABLE_HALF_JOIN2: Config<bool> = Config::new(
        -    "enable_half_join2", true);
         fn b() {}
        diff --git a/src/c.rs b/src/c.rs
        --- a/src/c.rs
        +++ b/src/c.rs
        @@ -1,2 +1,2 @@
        -    let x = compute_thing(1);
        +    let x = compute_thing(2);
        """
        let files = DiffParser.parse(diff)
        let groups = HunkGrouper.group(files)
        let flag = groups.first { $0.symbols.contains("ENABLE_HALF_JOIN2") }
        XCTAssertNotNil(flag)
        XCTAssertEqual(flag?.kind, .removes)
        XCTAssertEqual(flag?.keys.count, 2)
        XCTAssertFalse(groups.contains { $0.symbols.contains("compute_thing") })
    }
}

final class GroupingDiffTests: XCTestCase {
    /// Prints the groups for a real diff: SPELUNK_GROUP_DIFF=/path/to.diff swift test --filter GroupingDiffTests
    func testPrintGroups() throws {
        guard let path = ProcessInfo.processInfo.environment["SPELUNK_GROUP_DIFF"] else { throw XCTSkip("SPELUNK_GROUP_DIFF not set") }
        let files = DiffParser.parse(try String(contentsOfFile: path, encoding: .utf8))
        let byKey = Dictionary(files.flatMap(\.hunks).map { ($0.contentKey, $0) }, uniquingKeysWith: { a, _ in a })
        for g in HunkGrouper.group(files) {
            let paths = Set(g.keys.compactMap { byKey[$0]?.path })
            print("GROUP \(g.title)  hunks=\(g.keys.count) files=\(paths.count)")
        }
    }
}

final class HunkIdentityTests: XCTestCase {
    func diff(_ firstHunkBody: String) -> String {
        """
        diff --git a/src/a.rs b/src/a.rs
        --- a/src/a.rs
        +++ b/src/a.rs
        @@ -1,2 +1,2 @@
         fn a() {
        \(firstHunkBody)
        @@ -10,2 +10,2 @@
         fn b() {
        -    old();
        +    new();
        @@ -20,2 +20,2 @@
         fn c() {
        -    old();
        +    new();
        """
    }

    /// Ids depend on content, so an edit to an earlier hunk does not move later hunks' ids, and two
    /// identical hunks in one file stay distinct.
    func testIdsSurviveEditsElsewhere() {
        let a = DiffParser.parse(diff("-    x();\n+    y();"))[0].hunks
        let b = DiffParser.parse(diff("-    x();\n+    z();"))[0].hunks
        XCTAssertNotEqual(a[0].id, b[0].id)
        XCTAssertEqual(a[1].id, b[1].id)
        XCTAssertEqual(a[2].id, b[2].id)
        XCTAssertNotEqual(a[1].id, a[2].id)
        XCTAssertEqual(a[1].contentKey, a[2].contentKey)
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testDrainsAllOutput() async throws {
        let o = try await ProcessRunner.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\\\0' x; echo done >&2"], environment: [:])
        XCTAssertEqual(o.stdout.count, 3_000_000)
        XCTAssertEqual(String(decoding: o.stderr, as: UTF8.self), "done\n")
    }

    func testTimeout() async {
        let start = Date()
        do {
            _ = try await ProcessRunner.run("/bin/sleep", ["10"], environment: [:], timeout: 0.5)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        }
    }

    func testCancellationTerminates() async {
        let start = Date()
        let t = Task { try await ProcessRunner.run("/bin/sleep", ["10"], environment: [:]) }
        try? await Task.sleep(for: .milliseconds(300))
        t.cancel()
        let r = await t.result
        if case .success = r { XCTFail("expected cancellation") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testStreamsStdinThrough() async throws {
        let input = String(repeating: "abc\n", count: 50_000)
        let o = try await ProcessRunner.run("/bin/cat", [], environment: [:], stdin: Data(input.utf8))
        XCTAssertEqual(o.stdout.count, input.utf8.count)
    }
}
