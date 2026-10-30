import ToolSupport

struct RequirementScope {
	enum Place {
		case listed
		case part
		case earlierPart
	}

	static let milestoneFour = RequirementScope(
		table: "milestone-4.json",
		listed: numbered("B17.", 6) + numbered("B18.", 7) + numbered("B19.", 2)
			+ numbered("B20.", 5) + numbered("B21.", 5) + numbered("A", 18) + numbered("B", 13)
			+ numbered("C", 8) + numbered("D", 12)
			+ ["X01", "X02", "X04", "X05", "X06", "G03", "G04", "G05", "G06", "G10"],
		parts: [],
		agreedDifferences: [
			"B17.01/utc", "B17.06/head-unit", "B18.07/model-call", "B20.01/zones", "X04/zone",
			"G06/midnight",
		],
		decisionRecords: ["ADR-0083"], retained: [])

	static let milestoneFive = RequirementScope(
		table: "milestone-5.json",
		listed: numbered("B15.", 5) + ["B19.03", "G07", "X08"],
		parts: [
			"B14.01/saved-plan", "B12.04/saved-plan", "B16.01/plan-save", "B09.01/plan-save",
			"B01.03/saved-plan", "B07.04/saved-plan", "X05/saved-plan", "G03/plans", "D06/plan",
			"D14/plan",
		],
		agreedDifferences: [
			"B15.01/acknowledgement", "B15.01/arguments", "B15.03/phone-day", "B19.03/durable",
			"B19.03/step-limit", "B15.05/plan-unavailable", "B15.05/size", "B15.05/sorted-keys",
			"B15.05/two-calls", "B15.05/plan-schema", "B15.05/save-plan-sentence",
			"B15.05/save-draft", "B15.02/exact-numbers",
		],
		decisionRecords: ["ADR-0083", "ADR-0084"], retained: [])

	static let milestoneSixTable = "milestone-6.json"

	let table: String
	let listed: [String]
	let parts: [String]
	let agreedDifferences: [String]
	let decisionRecords: [String]
	let retained: [String]

	static func milestoneSix(_ retained: RetainedRequirements) -> RequirementScope {
		RequirementScope(
			table: milestoneSixTable, listed: retained.ids(inMilestone: 6), parts: [],
			agreedDifferences: retained.differences.map(\.sub), decisionRecords: ["ADR-0085"],
			retained: retained.requirements.map(\.id))
	}

	static func of(table path: String, retained: RetainedRequirements?) throws -> RequirementScope?
	{
		let name = NodePath.basename(path)
		guard name.hasSameUnits(as: milestoneSixTable) else {
			return [milestoneFour, milestoneFive].first { name.hasSameUnits(as: $0.table) }
		}
		guard let retained else {
			throw CoverageFailure(
				description:
					"\(path) is checked against \(RetainedRequirements.path), which does not exist")
		}
		return milestoneSix(retained)
	}

	func place(of identifier: String) -> Result<Place, Unplaced> {
		if parts.contains(identifier) { return .success(.earlierPart) }
		if agreedDifferences.contains(identifier) { return .success(.part) }
		let segments = identifier.split(
			separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
		guard segments.count == 2 else {
			return listed.contains(identifier) ? .success(.listed) : .failure(.unknownRequirement)
		}
		guard !segments[1].isEmpty, !segments[1].contains("/") else {
			return .failure(.unknownRequirement)
		}
		return listed.contains(String(segments[0])) ? .success(.part) : .failure(.unknownParent)
	}

	private static func numbered(_ prefix: String, _ count: Int) -> [String] {
		(1...count).map { "\(prefix)\($0 < 10 ? "0" : "")\($0)" }
	}
}

enum Unplaced: String, Error {
	case unknownRequirement = "unknown-requirement"
	case unknownParent = "unknown-parent"
}

struct Plan {
	let milestone: Milestone
	let requirements: [(identifier: String, criteria: [String])]

	init(declaredIn plan: JSONValue) throws {
		guard case .object = plan else {
			throw CoverageFailure(description: "the table lists requirements but declares no plan")
		}
		milestone = try Milestone(units: plan.member("units"), of: "the plan")
		guard case .object(let members) = try plan.member("requirements") else {
			throw CoverageFailure(description: "the plan declares no requirements")
		}
		requirements = try members.map { member in
			let criteria = try member.value.elements().map { element in
				guard let identifier = element.text else {
					throw CoverageFailure(
						description: "the plan of \(member.key) names a criterion that is not text")
				}
				return identifier
			}
			return (member.key, criteria)
		}
	}

	func count(of unit: String) -> Int? {
		milestone.units.first { $0.name == unit }?.criteria
	}

	func criteria(of requirement: String) -> [String] {
		requirements.first { $0.identifier == requirement }?.criteria ?? []
	}
}

struct Requirements {
	let plan: Plan
	let rows: [JSONValue]
	let open: [JSONValue]

	init?(declaredIn table: JSONValue) throws {
		let rows = try table.member("requirements")
		if case .undefined = rows { return nil }
		self.rows = try rows.elements()
		plan = try Plan(declaredIn: table.member("plan"))
		open = try table.member("open").elements()
	}
}

struct RequirementChecker {
	let requirements: Requirements
	let scope: RequirementScope
	let problems: Problems
	let criteria: Set<String>
	let tested: Set<String>

	func run(units: [Milestone.Unit]) throws {
		try checkPlan(against: units)
		let open = try openIdentifiers()
		var closed: Set<String> = []
		var differences: Set<String> = []
		for (index, row) in requirements.rows.enumerated() {
			guard let identifier = try row.member("id").text else {
				try problems.report("requirement \(index + 1)", "no-identifier")
				continue
			}
			guard let place = try place(of: identifier) else { continue }
			if !closed.insert(identifier).inserted {
				try problems.report(identifier, "duplicate-requirement")
			}
			if open.contains(identifier) {
				try problems.report(identifier, "closed-but-open")
			}
			if try row.member("statement").text == nil {
				try problems.report(identifier, "no-statement")
			}
			if try check(row, identifier, at: place) {
				differences.insert(identifier)
			}
		}
		for identifier in scope.listed + scope.parts
		where !closed.contains(identifier) && !open.contains(identifier) {
			try problems.report(identifier, "missing-requirement")
		}
		for identifier in scope.agreedDifferences
		where !differences.contains(identifier) && !open.contains(identifier) {
			try problems.report(identifier, "missing-agreed-difference")
		}
	}

	private func checkPlan(against units: [Milestone.Unit]) throws {
		let plan = requirements.plan
		for unit in units {
			guard let planned = plan.count(of: unit.name) else {
				try problems.report(unit.name, "unplanned-unit")
				continue
			}
			if unit.criteria < planned {
				try problems.report(
					unit.name, "below-plan", "declares \(unit.criteria) of \(planned)")
			}
		}
		let plannedCriteria = Set(plan.milestone.units.flatMap(\.identifiers))
		for planned in plan.requirements {
			for criterion in planned.criteria where !plannedCriteria.contains(criterion) {
				try problems.report(planned.identifier, "unplanned-criterion", criterion)
			}
		}
		for identifier in scope.listed
		where !plan.requirements.contains(where: { $0.identifier == identifier }) {
			try problems.report(identifier, "unplanned-requirement")
		}
	}

	private func openIdentifiers() throws -> Set<String> {
		var open: Set<String> = []
		for (index, entry) in requirements.open.enumerated() {
			guard let identifier = entry.text else {
				try problems.report("open \(index + 1)", "no-identifier")
				continue
			}
			if try place(of: identifier) != nil {
				open.insert(identifier)
			}
		}
		return open
	}

	private func place(of identifier: String) throws -> RequirementScope.Place? {
		switch scope.place(of: identifier) {
		case .success(let place):
			return place
		case .failure(let unplaced):
			try problems.report(identifier, unplaced.rawValue)
			return nil
		}
	}

	private func check(
		_ row: JSONValue, _ identifier: String, at place: RequirementScope.Place
	) throws -> Bool {
		let listed = try row.member("criteria")
		let named = listed.isTruthy ? try listed.elements() : []
		switch (named.isEmpty, try row.member("agreedDifference").text) {
		case (true, nil):
			try problems.report(identifier, "no-proof")
		case (false, .some):
			try problems.report(identifier, "more-than-one-proof")
		case (true, let difference?):
			if !scope.decisionRecords.contains(where: difference.contains) {
				try problems.report(identifier, "difference-without-adr")
			}
			if place == .part {
				try checkReaches(of: row, identifier)
			} else {
				try problems.report(identifier, "difference-on-parent")
			}
			return true
		case (false, nil):
			try checkCriteria(named.map { $0.text ?? $0.compactText }, of: row, identifier)
		}
		return false
	}

	private func checkReaches(of row: JSONValue, _ identifier: String) throws {
		let listed = try row.member("reaches")
		let reaches = listed.isTruthy ? try listed.elements() : []
		for entry in reaches where !(entry.text.map(scope.retained.contains) ?? false) {
			try problems.report(identifier, "unknown-reach", entry.text ?? entry.compactText)
		}
		let parent = String(identifier.prefix { $0 != "/" })
		if reaches.isEmpty, !scope.listed.contains(parent), !scope.retained.contains(parent) {
			try problems.report(identifier, "difference-reach-missing")
		}
	}

	private func checkCriteria(
		_ named: [String], of row: JSONValue, _ identifier: String
	) throws {
		for criterion in named where !criteria.contains(criterion) {
			try problems.report(identifier, "unknown-criterion", criterion)
		}
		let planned = requirements.plan.criteria(of: identifier)
		if named.sorted() != planned.sorted() {
			let listed = planned.isEmpty ? "none" : planned.joined(separator: ", ")
			try problems.report(identifier, "differs-from-plan", "planned \(listed)")
		}
		if !named.contains(where: tested.contains),
			try row.member("phoneSessionOnly").text == nil
		{
			try problems.report(identifier, "no-named-test")
		}
	}
}
