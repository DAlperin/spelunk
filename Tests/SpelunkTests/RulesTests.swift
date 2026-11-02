import XCTest
@testable import Spelunk

final class RulesTests: XCTestCase {
    func hunk(_ removed: [(Int, String)], _ added: [(Int, String)], path: String = "src/x.rs") -> (FileDiff, Hunk) {
        let lines = removed.map { DiffLine(kind: .removed, text: $0.1, oldLine: $0.0, newLine: nil) }
            + added.map { DiffLine(kind: .added, text: $0.1, oldLine: nil, newLine: $0.0) }
        let h = Hunk(id: "\(path)#0", path: path, oldStart: 1, oldCount: removed.count, newStart: 1, newCount: added.count, header: "", lines: lines)
        return (FileDiff(oldPath: path, newPath: path, status: .modified, hunks: [h]), h)
    }

    func evaluate(_ rules: String, _ f: FileDiff, _ h: Hunk, old: SourceDocument? = nil, new: SourceDocument? = nil) -> RuleSet.Outcome {
        let parsed = RuleParser.parse(rules, source: "test")
        XCTAssertEqual(parsed.errors, [])
        let set = RuleSet(rules: parsed.rules + ReviewRules.shared.defaultsOnly.rules.filter { !parsed.disabled.contains($0.reason) })
        return set.evaluate(ChangeClassifier.facts(file: f, hunk: h, oldDoc: old, newDoc: new))
    }

    func testGlob() throws {
        let re = try RuleParser.glob("doc/**/*.{md,rst}")
        func m(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil }
        XCTAssertTrue(m("doc/design/x.md"))
        XCTAssertTrue(m("doc/x.rst"))
        XCTAssertFalse(m("src/doc/x.md"))
        XCTAssertFalse(m("doc/x.rs"))
    }

    func testUserRuleOverridesDefaults() {
        let (f, h) = hunk([], [(0, "Some new design prose.")], path: "doc/developer/design/20261102_paths.md")
        XCTAssertEqual(evaluate("", f, h).tier, .docs)
        let o = evaluate("""
        rule critical "design doc"
          path ~ doc/developer/design/**
        """, f, h)
        XCTAssertEqual(o.tier, .critical)
        XCTAssertEqual(o.reasons, ["design doc"])
        XCTAssertEqual(o.rule, "test:1")
    }

    func testCollectListsSeveralRiskReasons() {
        let (f, h) = hunk([], [(0, "let g = m.lock().unwrap();")])
        let o = evaluate("", f, h)
        XCTAssertEqual(o.tier, .critical)
        XCTAssertEqual(Set(o.reasons), ["locking", "adds panic path"])
    }

    func testDisableAndNotes() {
        let (f, h) = hunk([(0, "// old comment"), (1, "let x = 1;")], [(0, "// new comment"), (1, "let x = 1;")])
        XCTAssertEqual(evaluate("", f, h).tier, .mechanical)
        let o = evaluate("disable \"comment wording\"", f, h)
        XCTAssertEqual(o.tier, .docs)
        XCTAssertEqual(o.reasons, ["comments"])
    }

    func testParseErrors() {
        let r = RuleParser.parse("""
        rule sideways "x"
        rule critical "y"
          hunk nonsense
          code touches unquoted
        bogus
        """, source: "f")
        XCTAssertEqual(r.errors.count, 4, "\(r.errors)")
        XCTAssertTrue(r.errors[0].hasPrefix("f:1:"))
    }

    func testTreeSitterQuery() {
        let old = SourceDocument(path: "src/x.rs", text: "async fn f(m: &M) {\n    let g = m.get();\n    work().await;\n}\n")
        let new = SourceDocument(path: "src/x.rs", text: "async fn f(m: &M) {\n    let g = m.lock();\n    work().await;\n}\n")
        let (f, _) = hunk([], [])
        let lines = [DiffLine(kind: .removed, text: "    let g = m.get();", oldLine: 1, newLine: nil),
                     DiffLine(kind: .added, text: "    let g = m.lock();", oldLine: nil, newLine: 1)]
        let h = Hunk(id: "x#0", path: "src/x.rs", oldStart: 2, oldCount: 1, newStart: 2, newCount: 1, header: "", lines: lines)
        let rules = """
        rule critical "lock taken in async fn"
          ts query (function_item (function_modifiers) body: (block (let_declaration value: (call_expression function: (field_expression field: (field_identifier) @f (#eq? @f "lock"))))))
        """
        let o = evaluate(rules, f, h, old: old, new: new)
        XCTAssertEqual(o.reasons.first, "lock taken in async fn")
        // The same query does not fire when the change is elsewhere.
        let other = Hunk(id: "x#1", path: "src/x.rs", oldStart: 3, oldCount: 1, newStart: 3, newCount: 1, header: "",
                         lines: [DiffLine(kind: .removed, text: "    work().await;", oldLine: 2, newLine: nil),
                                 DiffLine(kind: .added, text: "    work2().await;", oldLine: nil, newLine: 2)])
        XCTAssertNotEqual(evaluate(rules, f, other, old: old, new: new).reasons.first, "lock taken in async fn")
    }
}
