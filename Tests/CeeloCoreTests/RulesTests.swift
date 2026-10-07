import XCTest
@testable import CeeloCore

final class RulesFileTests: XCTestCase {
    private var dir: TempSoundsDirectory!

    override func setUpWithError() throws {
        dir = try TempSoundsDirectory(files: ["chime.wav", "soft_bell.mp3", "extra/horn.wav", "notes.txt"])
    }

    override func tearDown() {
        dir = nil
    }

    private func load(_ json: String?) throws -> [SoundRule] {
        guard let json else { return try loadRules(soundsDir: dir.url, rulesFile: nil) }
        try dir.write("rules.json", contents: json)
        return try loadRules(soundsDir: dir.url, rulesFile: dir.url.appendingPathComponent("rules.json"))
    }

    private func problems(_ json: String) -> [String] {
        do {
            _ = try load(json)
            return []
        } catch let error as RulesError {
            return error.problems
        } catch {
            return ["unexpected \(error)"]
        }
    }

    func testWithoutARulesFileEachFileNameIsItsPhrase() throws {
        let rules = try load(nil)
        XCTAssertEqual(rules.map(\.name), ["chime", "soft_bell"])
        XCTAssertEqual(rules.map(\.summary), [
            "chime: \"chime\" (words)  [file name]",
            "soft_bell: \"soft bell\" (words)  [file name]"
        ])
    }

    func testRulesOverrideFileNamesAndApplyDefaults() throws {
        let rules = try load(#"""
        {
          "defaults": { "match": "fuzzy", "within": 5 },
          "rules": [
            { "sound": "Chime", "say": ["new ticket"], "after": ["heads up"] },
            { "sound": "extra/horn.wav", "say": ["epic"], "match": "contains", "within": 2.5 }
          ]
        }
        """#)
        XCTAssertEqual(rules.map(\.name), ["chime", "horn", "soft_bell"])
        XCTAssertEqual(rules[0].summary,
                       "chime: \"new ticket\" after \"heads up\" within 5s (fuzzy)")
        XCTAssertEqual(rules[0].origin, .rulesFile(1))
        XCTAssertEqual(rules[1].summary, "horn: \"epic\" (contains)")
        XCTAssertEqual(rules[1].within, 2.5)
        XCTAssertEqual(rules[2].origin, .fileName)
    }

    func testEmptySayTurnsASoundOff() throws {
        let rules = try load(#"{"rules": [{"sound": "soft_bell.mp3", "say": []}]}"#)
        XCTAssertEqual(rules.first?.summary, "soft_bell: off")
        XCTAssertFalse(rules.first?.isEnabled ?? true)
    }

    func testEveryProblemIsReported() {
        let found = problems(#"""
        {
          "global": {},
          "defaults": { "match": "nope", "within": -1, "cooldown": 2 },
          "rules": [
            "not an object",
            { "sound": "missing", "say": ["hi"] },
            { "say": ["hi"] },
            { "sound": "chime" },
            { "sound": "chime", "say": "hi", "trigger_any": ["x"] },
            { "sound": "chime", "say": ["?"], "within": "soon", "after": [true] },
            { "sound": "chime", "say": ["hi"], "within": true }
          ]
        }
        """#)
        let expected = [
            "top level: unknown key \"global\"",
            "defaults: unknown key \"cooldown\"",
            "defaults: \"match\" must be one of: words, fuzzy, contains",
            "defaults: \"within\" must be a number of seconds",
            "rule 1: must be an object",
            "rule 2 (missing): no sound file \"missing\"",
            "rule 3: \"sound\" is required",
            "rule 4 (chime): \"say\" is required (use [] to switch the sound off)",
            "rule 5 (chime): unknown key \"trigger_any\"",
            "rule 5 (chime): \"say\" must be a list of phrases",
            "rule 6 (chime): \"say\" phrase \"?\" has no words",
            "rule 6 (chime): \"within\" must be a number of seconds",
            "rule 6 (chime): \"after\" must be a list of phrases",
            "rule 7 (chime): \"within\" must be a number of seconds"
        ]
        for message in expected {
            XCTAssertTrue(found.contains { $0.contains(message) }, "missing problem: \(message)\nfound: \(found)")
        }
        XCTAssertTrue(found.allSatisfy { $0.hasPrefix("rules.json: ") })
    }

    func testMalformedFiles() {
        XCTAssertTrue(problems("{ not json").first?.contains("rules.json") ?? false)
        XCTAssertEqual(problems("[1, 2]"), ["rules.json: expected a JSON object with \"rules\""])
        XCTAssertEqual(problems(#"{"defaults": 3}"#), ["\"defaults\" must be an object", "\"rules\" must be a list of rules"])
    }

    func testNoSoundsIsAnError() throws {
        let empty = try TempSoundsDirectory(files: ["readme.txt"])
        XCTAssertThrowsError(try loadRules(soundsDir: empty.url, rulesFile: nil)) {
            XCTAssertTrue("\($0)".contains("No sounds"))
        }
    }

    func testErrorDescription() {
        XCTAssertEqual("\(RulesError(problems: ["a"]))", "Rules have 1 problem:\n  - a")
        XCTAssertEqual("\(RulesError(problems: ["a", "b"]))", "Rules have 2 problems:\n  - a\n  - b")
    }
}

final class RuleEngineTests: XCTestCase {
    private let chime = URL(fileURLWithPath: "/sounds/chime.wav")
    private let horn = URL(fileURLWithPath: "/sounds/horn.wav")

    private func engine(_ rules: [SoundRule], guardSec: TimeInterval = 0) -> (RuleEngine, RecordingPlayer) {
        let player = RecordingPlayer()
        return (RuleEngine(rules: rules, player: player, refireGuardSec: guardSec), player)
    }

    func testWordsMatchWholeWordsWithSpellingAndNumberTolerance() {
        let (rules, player) = engine([
            SoundRule(sound: chime, say: ["favourite"]),
            SoundRule(sound: horn, say: ["fifteen"])
        ])
        rules.handle(text: "my favorite costs £15", at: t0)
        XCTAssertEqual(player.playedNames, ["chime", "horn"])
        rules.handle(text: "favourites", at: t0.addingTimeInterval(10))
        XCTAssertEqual(player.played.count, 3, "one letter of difference in a long word")
        rules.handle(text: "sixteen", at: t0.addingTimeInterval(20))
        XCTAssertEqual(player.played.count, 3)
    }

    func testContainsAndFuzzyModes() {
        let (rules, player) = engine([
            SoundRule(sound: chime, say: ["epic"], match: .contains),
            SoundRule(sound: horn, say: ["yoda"], match: .fuzzy)
        ])
        rules.handle(text: "Epically, Yuda said", at: t0)
        XCTAssertEqual(player.playedNames, ["chime", "horn"])
    }

    func testAfterMustComeFirstInTheSameTranscriptOrRecently() {
        let (rules, player) = engine([SoundRule(sound: chime, say: ["new ticket"], after: ["heads up"], within: 10)])
        rules.handle(text: "new ticket", at: t0)
        XCTAssertTrue(player.played.isEmpty, "never heard the setup")
        rules.handle(text: "new ticket heads up", at: t0.addingTimeInterval(1))
        XCTAssertTrue(player.played.isEmpty, "setup after the trigger")
        rules.handle(text: "heads up new ticket", at: t0.addingTimeInterval(2))
        XCTAssertEqual(player.played.count, 1)

        rules.handle(text: "heads up everyone", at: t0.addingTimeInterval(20))
        rules.handle(text: "new ticket", at: t0.addingTimeInterval(25))
        XCTAssertEqual(player.played.count, 2, "setup 5s earlier")
        rules.handle(text: "new ticket", at: t0.addingTimeInterval(40))
        XCTAssertEqual(player.played.count, 2, "setup expired")
    }

    func testAPhraseSeenInOverlappingWindowsPlaysOnce() {
        let (rules, player) = engine([SoundRule(sound: chime, say: ["go"])], guardSec: 3)
        for step in 0..<15 {
            rules.handle(text: "go", at: t0.addingTimeInterval(Double(step) * 0.2))
        }
        XCTAssertEqual(player.played.count, 1)
        rules.handle(text: "go", at: t0.addingTimeInterval(3))
        XCTAssertEqual(player.played.count, 2, "said again once the first has left the window")
    }

    func testSwitchedOffRulesNeverFireAndTriggersAreReported() {
        let player = RecordingPlayer()
        var reported: [String] = []
        let rules = RuleEngine(
            rules: [SoundRule(sound: chime, say: []), SoundRule(sound: horn, say: ["chime"])],
            player: player,
            onTrigger: { reported.append($0.name) }
        )
        rules.handle(text: "chime", at: t0)
        XCTAssertEqual(reported, ["horn"])
        XCTAssertEqual(player.playedNames, ["horn"])
    }
}
