import ToolSupport

struct Milestone {
	struct Unit {
		let name: String
		let criteria: Int

		var identifiers: [String] {
			(1...criteria).map { "\(name).\($0)" }
		}
	}

	let units: [Unit]

	init(units declared: JSONValue, of owner: String) throws {
		guard case .object(let members) = declared, !members.isEmpty else {
			throw CoverageFailure(description: "\(owner) declares no units")
		}
		units = try members.map { member in
			guard !member.key.isEmpty, let count = member.value.number,
				let criteria = Int(exactly: count), criteria > 0
			else {
				throw CoverageFailure(
					description: "unit \(member.key) does not declare a whole number of criteria")
			}
			return Unit(name: member.key, criteria: criteria)
		}
	}
}
