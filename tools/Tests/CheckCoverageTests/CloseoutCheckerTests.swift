import Foundation
import Testing
import ToolSupport

@testable import CheckCoverage

struct CloseoutCheckerTests {
	@Test(.timeLimit(.minutes(1)))
	func theFixturePassesAsWritten() throws {
		let result = try CloseoutFixture().run()
		#expect(result.errors == [])
		#expect(result.status == 0)
	}

	@Test(.timeLimit(.minutes(1)), arguments: CloseoutCase.pointers)
	func eachPointerKindFailsItsOwnRule(_ closeoutCase: CloseoutCase) throws {
		try closeoutCase.expectProblems()
	}

	@Test(.timeLimit(.minutes(1)), arguments: CloseoutCase.section, ["building", "final"])
	func theCommittedSectionMustBeTheDerivedOneAtEveryStage(
		_ closeoutCase: CloseoutCase, _ stage: String
	) throws {
		try closeoutCase.expectProblems(at: stage)
	}

	@Test(.timeLimit(.minutes(1)), arguments: [nil, "fail x", "blocked y", "pass"])
	func everyVerdictButPassFailsAtFinal(_ verdict: String?) throws {
		var fixture = CloseoutFixture()
		fixture.stage = "final"
		fixture.verdicts = verdict.map { ["closeout/lifecycle": $0] } ?? [:]
		let result = try fixture.run()
		let expected = verdict == "pass" ? [] : [verdict ?? "no verdict"]
		#expect(
			result.errors
				== expected.map {
					"\(CloseoutFixture.table): MOB01 [phone-step-not-passed] closeout/lifecycle \($0)"
				})
		#expect(result.status == (verdict == "pass" ? 0 : 1))
	}

	@Test(.timeLimit(.minutes(1)), arguments: ["building", "final"])
	func openRowsAndOpenEntriesFailOnlyAtFinal(_ stage: String) throws {
		var fixture = CloseoutFixture()
		fixture.stage = stage
		fixture.verdicts = [:]
		fixture.waitsOn = [("X03", #"{"work": "The offline half waits on its unit."}"#)]
		fixture.tables["coverage/milestone-4.json"] = #"""
			{"criteria": [], "requirements": [], "open": ["G05", "B17.01"]}
			"""#
		let result = try fixture.run()
		let table = CloseoutFixture.table
		#expect(
			result.errors
				== (stage == "final"
					? [
						"\(table): X03 [open-at-closeout]",
						"\(table): MOB01 [phone-step-not-passed] closeout/lifecycle no verdict",
						"\(table): G05 [open-at-closeout] coverage/milestone-4.json",
						"\(table): B17.01 [open-at-closeout] coverage/milestone-4.json",
					] : []))
	}

	@Test(.timeLimit(.minutes(1)), arguments: ["building", "final"])
	func requireFinalFailsWhileTheStageIsBuilding(_ stage: String) throws {
		var fixture = CloseoutFixture()
		fixture.stage = stage
		let result = try fixture.run(arguments: ["--require-final"])
		let notFinal =
			"\(HandEvidence.path): closeout [closeout-not-final] stage building"
		#expect(result.errors == (stage == "final" ? [] : [notFinal]))
		#expect(result.status == (stage == "final" ? 0 : 1))
	}
}

struct CloseoutCase: Sendable, CustomTestStringConvertible {
	let name: String
	var fixture = CloseoutFixture()
	var writing = true
	var edit: @Sendable (String) -> String = { $0 }
	let problems: [String]

	var testDescription: String { name }

	func expectProblems(at stage: String = "building") throws {
		var fixture = fixture
		fixture.stage = stage
		let result = try fixture.run(writing: writing, editing: edit)
		#expect(
			result.errors
				== problems.map {
					"\(CloseoutFixture.table): \($0.replacingOccurrences(of: "<stage>", with: stage))"
				})
		#expect(result.status == 1)
	}

	static func evidence(
		_ name: String, _ id: String, _ pointer: String, _ rule: String, _ details: String,
		table: (String, String)? = nil
	) -> CloseoutCase {
		var fixture = CloseoutFixture()
		fixture.handEvidence.append((id, pointer))
		if let table { fixture.tables[table.0] = table.1 }
		return CloseoutCase(name: name, fixture: fixture, problems: ["\(id) [\(rule)] \(details)"])
	}

	static func test(_ fields: String) -> String {
		#"{"test": {\#(fields)}}"#
	}

	static func row(_ kind: String, _ table: String, _ id: String) -> String {
		#"{"\#(kind)": {"table": "\#(table)", "id": "\#(id)"}}"#
	}

	static let three = "coverage/milestone-3.json"
	static let four = "coverage/milestone-4.json"
	static let six = CloseoutFixture.table

	static let pointers: [CloseoutCase] = [
		evidence(
			"a test file that does not exist", "B04.01",
			test(#""file": "Tests/Gone.swift", "function": "rangeIsRefused""#),
			"missing-test-file", "Tests/Gone.swift"),
		evidence(
			"a test function the file does not declare", "B04.01",
			test(#""file": "Tests/ReadTests.swift", "function": "rangeIsRefuse""#),
			"missing-test-function", "Tests/ReadTests.swift rangeIsRefuse"),
		evidence(
			"a proof method the class does not declare", "B04.01",
			test(
				#""file": "UITests/ShortcutProofs.swift", "class": "ShortcutProof", "method": "testGone""#
			),
			"missing-proof-method", "UITests/ShortcutProofs.swift ShortcutProof.testGone"),
		evidence(
			"a criterion of a table that does not exist", "X03",
			row("criterion", "coverage/milestone-9.json", "9.1.1"),
			"unknown-table", "coverage/milestone-9.json"),
		evidence(
			"a requirement of a file outside the coverage tables", "X03",
			row("requirement", "coverage/spec/retained.json", "B11.01"),
			"unknown-table", "coverage/spec/retained.json"),
		evidence(
			"a criterion the table does not have", "X03", row("criterion", three, "3.9.9"),
			"unknown-criterion-pointer", "\(three) 3.9.9"),
		evidence(
			"a criterion with no test or phone session", "X03", row("criterion", three, "3.1.3"),
			"unproven-criterion-pointer", "\(three) 3.1.3"),
		evidence(
			"a requirement the table has no row for", "X03", row("requirement", six, "B11.03"),
			"unknown-requirement-pointer", "\(six) B11.03"),
		evidence(
			"a requirement the table still lists as open", "X03", row("requirement", four, "G05"),
			"open-requirement-pointer", "\(four) G05",
			table: (four, #"{"criteria": [], "requirements": [], "open": ["G05"]}"#)),
		evidence(
			"a phone step its session does not have", "MOB01",
			#"{"phone": {"session": "closeout", "step": "closeout/gone"}}"#,
			"unknown-phone-step", "closeout closeout/gone"),
		evidence(
			"a phone step of a session that does not exist", "MOB01",
			#"{"phone": {"session": "m9", "step": "m9/list"}}"#, "unknown-phone-step", "m9 m9/list"),
		evidence(
			"a record on a row that is not a decision", "X03", #"{"record": "ADR-0085"}"#,
			"record-off-decision", "ADR-0085"),
		evidence(
			"a record that is not a known decision record", "D04", #"{"record": "ADR-0099"}"#,
			"unknown-record", "ADR-0099"),
		evidence(
			"a live scenario no live check names", "B13.01",
			#"{"live": {"scenario": "review-nowhere"}}"#,
			"unknown-live-scenario", "review-nowhere"),
		{
			var fixture = CloseoutFixture()
			fixture.handDifferences.append(
				("B13.01", #"{"recorded": {"record": "ADR-0099", "says": "It differs."}}"#))
			return CloseoutCase(
				name: "a recorded difference whose record is not known", fixture: fixture,
				problems: ["B13.01 [unknown-record] ADR-0099"])
		}(),
		{
			var fixture = CloseoutFixture()
			fixture.waitsOn.append(("MOB01", row("table", six, "B11.01")))
			return CloseoutCase(
				name: "an open reason that names a requirement its table has closed",
				fixture: fixture, problems: ["MOB01 [open-reason-not-open] \(six) B11.01"])
		}(),
	]

	static let section: [CloseoutCase] = [
		CloseoutCase(
			name: "a hand edit of a row's status",
			edit: {
				lines(of: $0) {
					$0.hasPrefix("\t\t\t{\"id\": \"D04\"")
						? $0.replacingOccurrences(
							of: #""status": "met""#, with: #""status": "open""#)
						: $0
				}
			},
			problems: ["D04 [stale-row] status"]),
		CloseoutCase(
			name: "a hand edit of a row's evidence and an added field",
			edit: {
				lines(of: $0) {
					$0.hasPrefix("\t\t\t{\"id\": \"X03\"")
						? $0.replacingOccurrences(of: "3.1.1", with: "3.1.2")
							.replacingOccurrences(
								of: #""waitsOn": []}"#, with: #""waitsOn": [], "note": "x"}"#) : $0
				}
			},
			problems: ["X03 [stale-row] evidence", "X03 [stale-row] note"]),
		CloseoutCase(
			name: "a section whose stage is not the hand evidence's",
			edit: {
				lines(of: $0) {
					$0.hasPrefix(CloseoutLayout.stagePrefix)
						? CloseoutLayout.stagePrefix + #""draft","# : $0
				}
			},
			problems: ["closeout [stale-stage] committed draft, \(HandEvidence.path) <stage>"]),
		CloseoutCase(
			name: "hand evidence and no section", writing: false,
			problems: ["closeout [missing-closeout-section]"]),
		CloseoutCase(
			name: "a retained id with no row",
			edit: { lines(of: $0) { $0.hasPrefix("\t\t\t{\"id\": \"D04\"") ? nil : $0 } },
			problems: ["D04 [missing-closeout-row]"]),
		CloseoutCase(
			name: "a row for an id that is not retained",
			edit: {
				lines(of: $0) {
					$0 == CloseoutLayout.rowsOpening ? $0 + "\n\t\t\t{\"id\": \"Z99\"}," : $0
				}
			},
			problems: ["Z99 [unknown-closeout-row]"]),
		CloseoutCase(
			name: "a row listed twice",
			edit: {
				lines(of: $0) { $0.hasPrefix("\t\t\t{\"id\": \"D04\"") ? $0 + "\n" + $0 : $0 }
			},
			problems: ["D04 [duplicate-closeout-row]"]),
		{
			var fixture = CloseoutFixture()
			fixture.handEvidence.removeAll { $0.id == "D04" }
			return CloseoutCase(
				name: "a row with no evidence, difference or open reason", fixture: fixture,
				problems: ["D04 [no-evidence]"])
		}(),
		{
			var fixture = CloseoutFixture()
			fixture.handEvidence.append(("Q01", #"{"record": "ADR-0085"}"#))
			fixture.waitsOn.append(("B99.01", #"{"work": "Not retained."}"#))
			return CloseoutCase(
				name: "hand evidence for ids that are not retained", fixture: fixture,
				problems: [
					"Q01 [hand-for-unretained] evidence", "B99.01 [hand-for-unretained] waitsOn",
				])
		}(),
	]

	static func lines(of text: String, _ change: (String) -> String?) -> String {
		text.components(separatedBy: "\n").compactMap(change).joined(separator: "\n")
	}
}
