struct Milestone: Sendable {
	struct Unit: Sendable {
		let name: String
		let criteria: Int

		var identifiers: [String] {
			criteria > 0 ? (1...criteria).map { "\(name).\($0)" } : []
		}
	}

	let table: String
	let units: [Unit]

	static let three = Milestone(
		table: "coverage/milestone-3.json",
		units: [
			Unit(name: "1.1", criteria: 6),
			Unit(name: "1.2", criteria: 10),
			Unit(name: "1.3", criteria: 7),
			Unit(name: "2.1", criteria: 7),
			Unit(name: "2.2", criteria: 7),
			Unit(name: "3.1", criteria: 10),
			Unit(name: "3.2", criteria: 8),
			Unit(name: "4.1", criteria: 7),
			Unit(name: "5.1", criteria: 12),
			Unit(name: "5.2", criteria: 6),
			Unit(name: "6.1", criteria: 5),
			Unit(name: "6.2", criteria: 5),
			Unit(name: "6.3", criteria: 4),
			Unit(name: "6.4", criteria: 5),
			Unit(name: "7.1", criteria: 4),
			Unit(name: "7.2", criteria: 5),
			Unit(name: "7.3", criteria: 5),
			Unit(name: "8.1", criteria: 5),
			Unit(name: "8.2", criteria: 5),
			Unit(name: "8.3", criteria: 5),
			Unit(name: "8.4", criteria: 6),
		])
}
