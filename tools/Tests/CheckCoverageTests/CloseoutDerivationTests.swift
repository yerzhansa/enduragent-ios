import Foundation
import Testing
import ToolSupport

@testable import CheckCoverage

struct CloseoutDerivationTests {
	static let four = "coverage/milestone-4.json"
	static let five = "coverage/milestone-5.json"
	static let six = "coverage/milestone-6.json"

	static var fixture: CloseoutFixture {
		var fixture = CloseoutFixture()
		fixture.retained = [
			RetainedID(id: "B04.01", group: .work, milestones: [1]),
			RetainedID(id: "B10.01", group: .work, milestones: [6]),
			RetainedID(id: "B11.01", group: .work, milestones: [6]),
			RetainedID(id: "B11.02", group: .work, milestones: [6]),
			RetainedID(id: "B13.01", group: .work, milestones: [2]),
			RetainedID(id: "B13.02", group: .work, milestones: [2]),
			RetainedID(id: "B15.01", group: .work, milestones: [5]),
			RetainedID(id: "B17.01", group: .work, milestones: [4]),
			RetainedID(id: "X03", group: .crossCutting, milestones: []),
			RetainedID(id: "G09", group: .journey, milestones: []),
			RetainedID(id: "D04", group: .decision, milestones: []),
			RetainedID(id: "MOB01", group: .mobile, milestones: []),
		]
		fixture.tables = [
			four: #"""
			{"requirements": [
				{"id": "B17.01", "criteria": ["4.1.1"]},
				{"id": "B17.01/utc", "agreedDifference": "ADR-0083 makes the phone's time zone decide."}
			], "open": []}
			"""#,
			five: #"""
			{"requirements": [{"id": "B15.01", "criteria": ["5.1.1"]}], "open": []}
			"""#,
			six: #"""
			{"requirements": [
				{"id": "B10.01", "criteria": ["1.1.5"]},
				{"id": "B17.01", "criteria": ["8.3.1"]},
				{"id": "B10.01/one-file", "agreedDifference": "ADR-0085 records it."},
				{"id": "B11/three-outcomes", "agreedDifference": "ADR-0085 records it.", "reaches": ["B11.01"]},
				{"id": "B13/reply", "agreedDifference": "ADR-0080 records it."},
				{"id": "B1/short", "agreedDifference": "ADR-0080 records it."},
				{"id": "G09/no-refresh", "agreedDifference": "ADR-0085 records it."}
			], "open": ["B11.02"]}
			"""#,
		]
		fixture.handEvidence = [
			("B04.01", CloseoutFixture.tested),
			("B17.01", CloseoutFixture.tested),
			("X03", #"{"criterion": {"table": "coverage/milestone-3.json", "id": "3.1.1"}}"#),
			("D04", #"{"record": "ADR-0085"}"#),
		]
		fixture.handDifferences = [
			("B13.01", #"{"recorded": {"record": "ADR-0080", "says": "Said once."}}"#)
		]
		fixture.waitsOn = [
			("B11.02", #"{"table": {"table": "coverage/milestone-6.json", "id": "B11.02"}}"#),
			("B13.02", #"{"work": "The reply half waits on its unit."}"#),
			("MOB01", #"{"phone": {"session": "closeout", "step": "closeout/lifecycle"}}"#),
		]
		return fixture
	}

	@Test(.timeLimit(.minutes(1)))
	func everyRetainedIdPointsAtItsRequirementRowsAndTakesTheStatusItsReasonsGive() throws {
		let section = try Self.fixture.section()
		let test = EvidencePointer.test(
			file: CloseoutFixture.readTests, name: .function("rangeIsRefused"))
		#expect(section.stage == .building)
		#expect(
			section.rows.map { [$0.id: $0.evidence] } == [
				["B04.01": [test]],
				["B10.01": [.requirement(table: Self.six, id: "B10.01")]],
				["B11.01": []],
				["B11.02": []],
				["B13.01": []],
				["B13.02": []],
				["B15.01": [.requirement(table: Self.five, id: "B15.01")]],
				[
					"B17.01": [
						.requirement(table: Self.four, id: "B17.01"),
						.requirement(table: Self.six, id: "B17.01"), test,
					]
				],
				["X03": [.criterion(table: "coverage/milestone-3.json", id: "3.1.1")]],
				["G09": []],
				["D04": [.record("ADR-0085")]],
				["MOB01": []],
			])
		#expect(
			section.rows.map { "\($0.id) \($0.group.rawValue) \($0.status.rawValue)" } == [
				"B04.01 work met", "B10.01 work deviation", "B11.01 work deviation",
				"B11.02 work open", "B13.01 work deviation", "B13.02 work open",
				"B15.01 work met", "B17.01 work deviation", "X03 crossCutting met",
				"G09 journey deviation", "D04 decision met", "MOB01 mobile open",
			])
		#expect(
			section.rows.filter { !$0.waitsOn.isEmpty }.map { [$0.id: $0.waitsOn] } == [
				["B11.02": [.table(Self.six, id: "B11.02")]],
				["B13.02": [.work("The reply half waits on its unit.")]],
				["MOB01": [.phone(session: "closeout", step: "closeout/lifecycle")]],
			])
	}

	@Test(.timeLimit(.minutes(1)))
	func anAgreedDifferenceReachesItsParentAndChildrenOrOnlyTheIdsItNames() throws {
		let section = try Self.fixture.section()
		#expect(
			section.rows.filter { !$0.differences.isEmpty }.map { [$0.id: $0.differences] } == [
				[
					"B10.01": [
						.agreed(table: Self.six, sub: "B10.01/one-file", record: "ADR-0085")
					]
				],
				[
					"B11.01": [
						.agreed(table: Self.six, sub: "B11/three-outcomes", record: "ADR-0085")
					]
				],
				[
					"B13.01": [
						.agreed(table: Self.six, sub: "B13/reply", record: "ADR-0080"),
						.recorded(record: "ADR-0080", says: "Said once."),
					]
				],
				["B13.02": [.agreed(table: Self.six, sub: "B13/reply", record: "ADR-0080")]],
				["B17.01": [.agreed(table: Self.four, sub: "B17.01/utc", record: "ADR-0083")]],
				["G09": [.agreed(table: Self.six, sub: "G09/no-refresh", record: "ADR-0085")]],
			])
	}
}
