import Foundation

@testable import EnduragentCoach

struct SeedListing: Sendable, Equatable {
	let id: String
	var name: String?
	var externalID: String?
	var start: String?
	var load: Double?
	var feel: Int?
	var rpe: Int?

	var isOurs: Bool { externalID?.hasPrefix(LiveSeedPlan.externalIDPrefix) ?? false }

	var label: String {
		"\(id) \"\(name ?? "no name")\" \(start ?? "no start")"
	}
}

protocol SeedAccount: Sendable {
	func activities(oldest: CivilDate, newest: CivilDate) async throws -> [SeedListing]
	func wellness(oldest: CivilDate, newest: CivilDate) async throws -> [CivilDate: [String:
		Double]]
	func upload(_ activity: SeedActivity, file: Data) async throws -> String
	func rate(_ id: String, feel: Int, rpe: Int) async throws
	func delete(_ id: String) async throws
	func writeWellness(_ days: [CivilDate: [String: Double?]]) async throws
}

struct SeedPolling: Sendable {
	let attempts: Int
	let interval: Duration
	let sleep: @Sendable (Duration) async throws -> Void
}

struct SeedOutcome: Sendable {
	var uploaded: [String] = []
	var kept: [String] = []
	var rated: [String] = []
	var wellnessWritten: [CivilDate] = []
	var wellnessKept = 0
	var listed: [SeedListing] = []
}

struct LiveSeeder {
	static let guardDays = 365

	let account: any SeedAccount
	let today: CivilDate
	let polling: SeedPolling
	var ledger: LiveSeedLedger

	mutating func seed(render: (SeedActivity) throws -> Data) async throws -> SeedOutcome {
		let listed = try await account.activities(
			oldest: today.adding(days: -Self.guardDays), newest: today)
		let foreign = listed.filter { !$0.isOurs }
		guard foreign.isEmpty else {
			throw LiveCheckStop(
				description:
					"Nothing was written: the account has activities the seed did not write: "
					+ foreign.map(\.label).joined(separator: "; "))
		}
		let plan = LiveSeedPlan(anchor: ledger.anchor ?? today)
		let current = try await account.wellness(oldest: plan.oldest, newest: plan.anchor)
		var outcome = SeedOutcome()
		var missing: [SeedWellnessDay] = []
		var foreignDays: [String] = []
		for day in plan.wellness {
			let values = current[day.date] ?? [:]
			if day.matches(values) {
				outcome.wellnessKept += 1
			} else if ledger.wellness[day.date] == nil,
				SeedWellnessDay.fields.contains(where: { values[$0] != nil })
			{
				foreignDays.append(day.date.rawValue)
			} else {
				missing.append(day)
			}
		}
		guard foreignDays.isEmpty else {
			throw LiveCheckStop(
				description:
					"Nothing was written: the account has wellness values the seed did not write on "
					+ foreignDays.joined(separator: ", "))
		}
		if ledger.anchor == nil {
			try ledger.record(anchor: plan.anchor)
		}
		let onAccount = Dictionary(
			listed.compactMap { row in row.externalID.map { ($0, row.id) } },
			uniquingKeysWith: { first, _ in first })
		for activity in plan.activities {
			if ledger.activities[activity.externalID] != nil {
				outcome.kept.append(activity.externalID)
			} else if let id = onAccount[activity.externalID] {
				try ledger.record(activity: activity.externalID, id: id)
				outcome.kept.append(activity.externalID)
			} else {
				let id = try await account.upload(activity, file: try render(activity))
				try ledger.record(activity: activity.externalID, id: id)
				outcome.uploaded.append(activity.externalID)
			}
		}
		let processed = try await waitUntilProcessed(plan)
		for activity in plan.activities {
			guard let feel = activity.feel, let rpe = activity.rpe,
				let id = ledger.activities[activity.externalID],
				let row = processed[id], row.feel != feel || row.rpe != rpe
			else { continue }
			try await account.rate(id, feel: feel, rpe: rpe)
			outcome.rated.append(activity.externalID)
		}
		if !missing.isEmpty {
			for day in missing {
				try ledger.record(wellness: day.date, fields: SeedWellnessDay.fields)
			}
			try await account.writeWellness(
				Dictionary(
					uniqueKeysWithValues: missing.map {
						($0.date, $0.values.mapValues(Optional.some))
					}))
			outcome.wellnessWritten = missing.map(\.date)
		}
		outcome.listed = try await account.activities(oldest: plan.oldest, newest: today)
			.filter(\.isOurs)
		return outcome
	}

	mutating func unseed(retiringLedgerAs retiredName: String) async throws -> [String] {
		let ids = ledger.activityIDs
		for id in ids {
			try await account.delete(id)
		}
		if !ledger.wellness.isEmpty {
			try await account.writeWellness(
				ledger.wellness.mapValues { fields in
					Dictionary(uniqueKeysWithValues: fields.map { ($0, Double?.none) })
				})
		}
		let remaining = try await account.activities(
			oldest: today.adding(days: -Self.guardDays), newest: today
		).filter(\.isOurs)
		guard remaining.isEmpty else {
			throw LiveCheckStop(
				description:
					"The account still lists seeded activities after unseeding: "
					+ remaining.map(\.label).joined(separator: "; "))
		}
		if FileManager.default.fileExists(atPath: ledger.file.path) {
			try ledger.retire(as: retiredName)
		}
		return ids
	}

	private func waitUntilProcessed(_ plan: LiveSeedPlan) async throws -> [String: SeedListing] {
		let ids = Set(plan.activities.compactMap { ledger.activities[$0.externalID] })
		var waiting = ids
		for attempt in 0..<polling.attempts {
			if attempt > 0 {
				try await polling.sleep(polling.interval)
			}
			let rows = try await account.activities(oldest: plan.oldest, newest: today)
			let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
			waiting = ids.filter { byID[$0]?.load == nil }
			if waiting.isEmpty {
				return byID
			}
		}
		throw LiveCheckStop(
			description:
				"These seeded activities never listed with a load after \(polling.attempts) reads: "
				+ waiting.sorted().joined(separator: ", "))
	}
}
