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
        (rule critical "design doc"
          (path "doc/developer/design/**"))
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
        let o = evaluate("(disable \"comment wording\")", f, h)
        XCTAssertEqual(o.tier, .docs)
        XCTAssertEqual(o.reasons, ["comments"])
    }

    func testParseErrors() {
        let r = RuleParser.parse("""
        (rule sideways "x")
        (rule critical "y"
          (hunk nonsense))
        (rule critical "z"
          (code touches "not a regex"))
        (bogus)
        (rule critical "w" undefined-name)
        """, source: "f")
        XCTAssertEqual(r.errors.count, 5, "\(r.errors)")
        XCTAssertTrue(r.errors[0].hasPrefix("f:1:"))
        XCTAssertTrue(r.errors[1].hasPrefix("f:3:"), "the bad condition's own line")
        XCTAssertEqual(RuleParser.parse("(rule critical \"x\"", source: "f").errors, ["f:1: `(` is never closed"])
    }

    func testTreeSitterQuery() {
        let old = SourceDocument(path: "src/x.rs", text: "async fn f(m: &M) {\n    let g = m.get();\n    work().await;\n}\n")
        let new = SourceDocument(path: "src/x.rs", text: "async fn f(m: &M) {\n    let g = m.lock();\n    work().await;\n}\n")
        let (f, _) = hunk([], [])
        let lines = [DiffLine(kind: .removed, text: "    let g = m.get();", oldLine: 1, newLine: nil),
                     DiffLine(kind: .added, text: "    let g = m.lock();", oldLine: nil, newLine: 1)]
        let h = Hunk(id: "x#0", path: "src/x.rs", oldStart: 2, oldCount: 1, newStart: 2, newCount: 1, header: "", lines: lines)
        let rules = #"""
        (rule critical "lock taken in async fn"
          (ts query "(function_item (function_modifiers) body: (block (let_declaration value: (call_expression function: (field_expression field: (field_identifier) @f (#eq? @f \"lock\"))))))"))
        """#
        let o = evaluate(rules, f, h, old: old, new: new)
        XCTAssertEqual(o.reasons.first, "lock taken in async fn")
        // The same query does not fire when the change is elsewhere.
        let other = Hunk(id: "x#1", path: "src/x.rs", oldStart: 3, oldCount: 1, newStart: 3, newCount: 1, header: "",
                         lines: [DiffLine(kind: .removed, text: "    work().await;", oldLine: 2, newLine: nil),
                                 DiffLine(kind: .added, text: "    work2().await;", oldLine: nil, newLine: 2)])
        XCTAssertNotEqual(evaluate(rules, f, other, old: old, new: new).reasons.first, "lock taken in async fn")
    }

    func testSemanticConditionsWaitForAnswers() {
        let (f, h) = hunk([], [(0, "x += 1;")])
        let rules = """
        (rule critical "hot path: {callers} callers"
          (lang rust)
          (callers > 2)
          (called-from /peek/ :depth 2))
        """
        let parsed = RuleParser.parse(rules, source: "test")
        XCTAssertEqual(parsed.errors, [])
        let set = RuleSet(rules: parsed.rules + ReviewRules.shared.defaultsOnly.rules)
        var facts = ChangeClassifier.facts(file: f, hunk: h, oldDoc: nil, newDoc: nil)
        let first = set.evaluate(facts)
        XCTAssertNotEqual(first.tier, .critical)
        XCTAssertTrue(first.pending.needs.callers)
        XCTAssertEqual(first.pending.needs.depth, 2)

        facts.semantic = SemanticFacts(callers: [.init(name: "a", path: "x.rs"), .init(name: "b", path: "y.rs"), .init(name: "c", path: "z.rs")],
                                       transitiveCallers: ["a", "sequence_peek"])
        let second = set.evaluate(facts)
        XCTAssertEqual(second.tier, .critical)
        XCTAssertEqual(second.reasons.first, "hot path: 3 callers")
        XCTAssertTrue(second.pending.isEmpty)

        facts.semantic = .unavailable
        XCTAssertNotEqual(set.evaluate(facts).tier, .critical)
    }

    func testLLMConditionAndAttach() {
        let text = """
        (rule critical "resolver change"
          (path "**/graphql/**")
          (llm "Does this add a resolver?"))

        (attach "Usage examples" :auto :per hunk :model sonnet
          (path "**/graphql/**")
          (claude "Show usage for {name}"))

        (attach "Broken"
          (path "**"))
        """
        let parsed = RuleParser.parseAll(text, source: "test")
        XCTAssertEqual(parsed.rules.count, 1)
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.errors.count, 1)
        let a = parsed.attachments[0]
        XCTAssertTrue(a.auto)
        XCTAssertEqual(a.scope, .hunk)
        XCTAssertEqual(a.model, "sonnet")
        if case .claude(let p) = a.action { XCTAssertEqual(p, "Show usage for {name}") } else { XCTFail("expected claude action") }

        let (f, h) = hunk([], [(0, "fn resolve_user() {}")], path: "src/graphql/user.rs")
        var facts = ChangeClassifier.facts(file: f, hunk: h, oldDoc: nil, newDoc: nil)
        let set = RuleSet(rules: parsed.rules)
        XCTAssertEqual(set.evaluate(facts).pending.questions, ["Does this add a resolver?"])
        XCTAssertEqual(RuleSet.match(a.conditions, facts), true)
        facts.answers["Does this add a resolver?"] = true
        XCTAssertEqual(set.evaluate(facts).tier, .critical)
    }

    func testCommentsAndRegexDelimiters() {
        let parsed = RuleParser.parse("""
        ; a comment
        (rule critical "lib" ; the crate root
          (path "src/lib.rs")
          (text touches /a#b;c\\/?/))
        """, source: "test")
        XCTAssertEqual(parsed.errors, [])
        let (f, h) = hunk([], [(0, "let x = \"a#b;c\";")], path: "src/lib.rs")
        let set = RuleSet(rules: parsed.rules)
        XCTAssertEqual(set.evaluate(ChangeClassifier.facts(file: f, hunk: h, oldDoc: nil, newDoc: nil)).tier, .critical)
    }

    func testUnavailableSemanticsDoNotFlipNegation() {
        let parsed = RuleParser.parse("""
        (rule critical "unused"
          (lang rust)
          (not (refs > 0)))
        """, source: "test")
        let (f, h) = hunk([], [(0, "fn x() {}")])
        var facts = ChangeClassifier.facts(file: f, hunk: h, oldDoc: nil, newDoc: nil)
        facts.semantic = .unavailable
        XCTAssertNotEqual(RuleSet(rules: parsed.rules).evaluate(facts).tier, .critical)
        facts.semantic = SemanticFacts(refs: 0)
        XCTAssertEqual(RuleSet(rules: parsed.rules).evaluate(facts).tier, .critical)
    }

    func testAnyAllAndDefine() {
        let parsed = RuleParser.parse("""
        (define risky (any (code touches /unsafe/) (path "**/ffi/**")))
        (rule critical "risky outside tests"
          (all risky (not (file test))))
        """, source: "test")
        XCTAssertEqual(parsed.errors, [])
        let set = RuleSet(rules: parsed.rules)
        let (f1, h1) = hunk([], [(0, "let x = 1;")], path: "src/ffi/bind.rs")
        XCTAssertEqual(set.evaluate(ChangeClassifier.facts(file: f1, hunk: h1, oldDoc: nil, newDoc: nil)).tier, .critical)
        let (f2, h2) = hunk([], [(0, "unsafe { x() }")], path: "src/a.rs")
        XCTAssertEqual(set.evaluate(ChangeClassifier.facts(file: f2, hunk: h2, oldDoc: nil, newDoc: nil)).tier, .critical)
        let (f3, h3) = hunk([], [(0, "let y = 2;")], path: "src/a.rs")
        XCTAssertNotEqual(set.evaluate(ChangeClassifier.facts(file: f3, hunk: h3, oldDoc: nil, newDoc: nil)).tier, .critical)
    }

    func testAnyWaitsOnlyWhenItCouldStillMatter() {
        let (f, h) = hunk([], [(0, "fn x() {}")], path: "src/a.rs")
        let facts = ChangeClassifier.facts(file: f, hunk: h, oldDoc: nil, newDoc: nil)
        // A known true branch decides `any`, so the semantic branch is never asked.
        let decided = RuleParser.parse("(rule critical \"x\" (any (lang rust) (refs > 5)))", source: "t").rules
        let o = RuleSet(rules: decided).evaluate(facts)
        XCTAssertEqual(o.tier, .critical)
        XCTAssertTrue(o.pending.isEmpty)
        // With only false known branches, the unknown one is what decides it.
        let waiting = RuleParser.parse("(rule critical \"x\" (any (lang python) (refs > 5)))", source: "t").rules
        XCTAssertTrue(RuleSet(rules: waiting).evaluate(facts).pending.needs.refs)
        // A known false part of `all` decides it without asking.
        let blocked = RuleParser.parse("(rule critical \"x\" (lang python) (llm \"q?\"))", source: "t").rules
        XCTAssertTrue(RuleSet(rules: blocked).evaluate(facts).pending.isEmpty)
    }

    func testLegacyFormatConverts() {
        let legacy = """
        # mine
        rule critical "join path" collect
          path ~ src/compute/src/render/**   # rendering
          not hunk in-test
          called-from /render_join|a\\/b/ depth 2
        attach "History" per file
          path ~ src/x/**
          run git log --oneline -8 -- {file}
          model sonnet
        disable "comment wording"
        """
        XCTAssertTrue(LegacyRules.isLegacy(legacy))
        let c = LegacyRules.convert(legacy)
        XCTAssertEqual(c.errors, [])
        XCTAssertFalse(LegacyRules.isLegacy(c.text))
        let p = RuleParser.parseAll(c.text, source: "t")
        XCTAssertEqual(p.errors, [])
        XCTAssertEqual(p.rules.first?.reason, "join path")
        XCTAssertEqual(p.rules.first?.collect, true)
        XCTAssertEqual(p.attachments.first?.model, "sonnet")
        if case .run(let cmd) = p.attachments.first?.action { XCTAssertEqual(cmd, "git log --oneline -8 -- {file}") } else { XCTFail("expected run") }
        XCTAssertEqual(p.disabled, ["comment wording"])
        XCTAssertTrue(c.text.contains("; rendering"))
        // Read as converted, with a note that the file is in the old format.
        let direct = RuleParser.parseAll(legacy, source: "t")
        XCTAssertEqual(direct.rules.count, 1)
        XCTAssertEqual(direct.errors.count, 1)
    }

    func testDefaultsParse() {
        XCTAssertEqual(RuleParser.parse(DefaultRules.text, source: "defaults").errors, [])
        XCTAssertFalse(LegacyRules.isLegacy(DefaultRules.text))
        XCTAssertEqual(RuleParser.parseAll(RulesFiles.template, source: "template").errors, [])
    }
}
