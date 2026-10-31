import Testing

@testable import CheckCoverage

extension RequirementCheckerTests {
	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.scopeByName)
	func tableIsCheckedAgainstTheScopeItsFileNameNames(_ requirementCase: RequirementCase) throws {
		#expect(try requirementCase.check() == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.sixPlacement)
	func milestoneSixPlacesOnlyAnAgreedDifferenceUnderAnUnlistedParent(
		_ requirementCase: RequirementCase
	) throws {
		#expect(try requirementCase.check() == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.decisionRecords)
	func agreedDifferenceNamesADecisionRecordOfItsScope(_ requirementCase: RequirementCase) throws {
		#expect(try requirementCase.check() == requirementCase.problems)
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.earlierParts)
	func partOfAnEarlierRequirementIsPlacedAndClosedOnlyByCriteria(
		_ requirementCase: RequirementCase
	) throws {
		#expect(try requirementCase.check() == requirementCase.problems)
	}

	@Test(
		.timeLimit(.minutes(1)),
		arguments: RequirementCase.fiveListed + RequirementCase.fiveParts)
	func everyRequirementAndPartOfMilestoneFiveIsOpenOrARow(_ identifier: String) throws {
		let requirementCase = RequirementCase.milestoneFive(
			"\(identifier) is neither open nor a row",
			open: RequirementCase.fiveOpen.filter { $0 != identifier })
		#expect(try requirementCase.check() == ["\(identifier) [missing-requirement]"])
	}

	@Test(.timeLimit(.minutes(1)), arguments: RequirementCase.fiveAgreed)
	func everyAgreedDifferenceOfMilestoneFiveIsOpenOrARow(_ identifier: String) throws {
		let requirementCase = RequirementCase.milestoneFive(
			"\(identifier) is neither open nor a row",
			open: RequirementCase.fiveOpen.filter { $0 != identifier })
		#expect(try requirementCase.check() == ["\(identifier) [missing-agreed-difference]"])
	}
}

extension RequirementCase {
	static let fiveListed = [
		"B15.01", "B15.02", "B15.03", "B15.04", "B15.05", "B19.03", "G07", "X08",
	]
	static let fiveParts = [
		"B14.01/saved-plan", "B12.04/saved-plan", "B16.01/plan-save", "B09.01/plan-save",
		"B01.03/saved-plan", "B07.04/saved-plan", "X05/saved-plan", "G03/plans", "D06/plan",
		"D14/plan",
	]
	static let fiveAgreed = [
		"B15.01/acknowledgement", "B15.01/arguments", "B15.03/phone-day", "B19.03/durable",
		"B19.03/step-limit", "B15.05/plan-unavailable", "B15.05/size", "B15.05/sorted-keys",
		"B15.05/two-calls", "B15.05/plan-schema", "B15.05/save-plan-sentence",
		"B15.05/save-draft", "B15.02/exact-numbers",
	]
	static let fiveOpen = fiveListed + fiveParts + fiveAgreed
	static let fivePlan = Dictionary(
		uniqueKeysWithValues: fiveListed.map { ($0, ["2.1.1"]) }
			+ fiveParts.map { ($0, ["1.1.1", "1.1.2"]) })

	static let scopeByName = [
		milestoneFive("the first Milestone 5 table holds every requirement in open"),
		milestoneFive(
			"a Milestone 4 requirement is outside Milestone 5",
			open: fiveOpen + ["B17.01"],
			problems: ["B17.01 [unknown-requirement]"]),
		RequirementCase(
			name: "a table of no known milestone lists requirements",
			path: "coverage/milestone-7.json",
			problems: ["requirements [unknown-scope]"]),
		RequirementCase(
			name: "a table named for no milestone lists requirements",
			path: "coverage/sample.json",
			problems: ["requirements [unknown-scope]"]),
	]

	static let sixListed = [
		"B01.01", "B01.02", "B01.03", "B01.04", "B05.01", "B05.02", "B05.03", "B05.04",
		"B10.01", "B10.02", "B10.03", "B10.04", "B11.01", "B11.02",
	]
	static let sixAgreed = [
		"B10.02/no-snapshot", "B10.03/no-snapshot", "B10.01/one-file", "B10.01/one-severity",
		"B01.02/store-notes", "B01.04/no-notice", "B01.03/no-update-state", "B11/three-outcomes",
		"G09/no-refresh",
	]
	static let sixRows = sixAgreed.map { identifier in
		identifier == "B11/three-outcomes"
			? sixDifference(identifier, #""reaches": ["B11.01"]"#) : sixDifference(identifier)
	}

	static let sixPlacement = [
		milestoneSix("the first Milestone 6 table records every agreed difference"),
		milestoneSix(
			"a sub-id of B11 that is no agreed difference is open",
			open: sixListed + ["B11/other"],
			problems: ["B11/other [unknown-parent]"]),
		milestoneSix(
			"a sub-id of B11 that is no agreed difference carries one",
			rows: sixRows + [sixDifference("B11/other", #""reaches": ["B11.01"]"#)],
			problems: ["B11/other [unknown-parent]"]),
	]

	static let sixReaches = [
		milestoneSix(
			"B11/three-outcomes reaches B11.01 and G09/no-refresh, under a retained id, reaches nothing"
		),
		milestoneSix(
			"B11/three-outcomes names no retained id it reaches",
			rows: sixRows.map {
				$0.contains("B11/three-outcomes") ? sixDifference("B11/three-outcomes") : $0
			},
			problems: ["B11/three-outcomes [difference-reach-missing]"]),
		milestoneSix(
			"B11/three-outcomes reaches an id that is not retained",
			rows: sixRows.map {
				$0.contains("B11/three-outcomes")
					? sixDifference("B11/three-outcomes", #""reaches": ["B11.03"]"#) : $0
			},
			problems: ["B11/three-outcomes [unknown-reach] B11.03"]),
	]

	static let decisionRecords = [
		milestoneFive(
			"a Milestone 5 agreed difference names ADR-0084",
			rows: [difference("B15.05/size", "ADR-0084 refuses a plan too large to load.")],
			open: fiveOpen.filter { $0 != "B15.05/size" }),
		milestoneFive(
			"a Milestone 5 agreed difference names ADR-0083",
			rows: [difference("B15.03/phone-day")],
			open: fiveOpen.filter { $0 != "B15.03/phone-day" }),
		milestoneFive(
			"a Milestone 5 agreed difference names neither decision",
			rows: [difference("B15.05/size", "ADR-0082 refuses a plan too large to load.")],
			open: fiveOpen.filter { $0 != "B15.05/size" },
			problems: ["B15.05/size [difference-without-adr]"]),
		RequirementCase(
			name: "a Milestone 4 agreed difference names only ADR-0084",
			rows: replacing(
				"X04/zone", with: difference("X04/zone", "ADR-0084 keeps the phone's day.")),
			problems: ["X04/zone [difference-without-adr]"]),
	]

	static let earlierParts = [
		milestoneFive(
			"a part is closed by its planned criteria though its parent is not listed",
			rows: [closing("B14.01/saved-plan", ["1.1.1", "1.1.2"])],
			open: fiveOpen.filter { $0 != "B14.01/saved-plan" }),
		milestoneFive(
			"a part carries an agreed difference",
			rows: [difference("B14.01/saved-plan", "ADR-0084 keeps the headline.")],
			open: fiveOpen.filter { $0 != "B14.01/saved-plan" },
			problems: ["B14.01/saved-plan [difference-on-parent]"]),
		milestoneFive(
			"a sub-id of an earlier requirement is not a part",
			open: fiveOpen + ["B14.01/headline"],
			problems: ["B14.01/headline [unknown-parent]"]),
		RequirementCase(
			name: "a part of Milestone 5 is outside Milestone 4",
			open: inScope.filter { $0 != "B17.01" } + ["B14.01/saved-plan"],
			problems: ["B14.01/saved-plan [unknown-parent]"]),
	]

	static func sixDifference(_ identifier: String, _ members: String...) -> String {
		proof(
			identifier,
			([#""agreedDifference": "ADR-0085 records it.""#] + members).joined(separator: ", "))
	}

	static func milestoneSix(
		_ name: String, rows: [String] = sixRows, open: [String] = sixListed,
		problems: [String] = []
	) -> RequirementCase {
		RequirementCase(
			name: name, path: "coverage/milestone-6.json", rows: rows, open: open,
			planned: Dictionary(uniqueKeysWithValues: sixListed.map { ($0, ["2.1.1"]) }),
			problems: problems, readsRetained: true)
	}

	static func milestoneFive(
		_ name: String, rows: [String] = [], open: [String] = fiveOpen, problems: [String] = []
	) -> RequirementCase {
		RequirementCase(
			name: name, path: "coverage/milestone-5.json", rows: rows, open: open,
			planned: fivePlan, problems: problems)
	}
}
