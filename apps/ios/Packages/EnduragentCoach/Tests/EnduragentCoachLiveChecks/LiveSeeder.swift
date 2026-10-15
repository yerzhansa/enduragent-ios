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

	var isOurs: Bool {
		externalID?.hasPrefix(LiveSeedPlan.externalIDPrefix) == true
			&& name?.hasPrefix(LiveSeedPlan.namePrefix) == true
	}

	var label: String {
		"\(id) \"\(name ?? "no name")\" \(start ?? "no start")"
	}
}

protocol SeedAccount: Sendable {
	func athleteID() async throws -> String
	func activities(oldest: CivilDate, newest: CivilDate) async throws -> [SeedListing]
	func wellness(oldest: CivilDate, newest: CivilDate) async throws -> [CivilDate: [String:
		Double]]
	func upload(_ activity: SeedActivity, file: Data) async throws -> String
	func activityExists(_ id: String) async throws -> Bool
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

struct UnseedOutcome: Sendable {
	var deleted: [String] = []
	var skipped: [String] = []
	var cleared: [CivilDate: [String]] = [:]
	var changedSinceSeed: [String] = []
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
		let athlete = try await confirmAccount(listing: listed)
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
		if ledger.athlete == nil {
			try ledger.record(athlete: athlete)
		}
		if ledger.anchor == nil {
			try ledger.record(anchor: plan.anchor)
		}
		let onAccount = Dictionary(
			listed.compactMap { row in row.externalID.map { ($0, row.id) } },
			uniquingKeysWith: { first, _ in first })
		let listedIDs = Set(listed.map(\.id))
		for activity in plan.activities {
			if let id = ledger.activities[activity.externalID],
				try await stillOnAccount(id, listed: listedIDs)
			{
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

	mutating func unseed(retiringLedgerAs retiredName: String) async throws -> UnseedOutcome {
		let listed = try await account.activities(
			oldest: today.adding(days: -Self.guardDays), newest: today)
		let athlete = try await confirmAccount(listing: listed)
		let ledgerOnDisk = FileManager.default.fileExists(atPath: ledger.file.path)
		if ledger.athlete == nil, ledgerOnDisk {
			try ledger.record(athlete: athlete)
		}
		var outcome = UnseedOutcome()
		let rows = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
		for (externalID, id) in ledger.activities.sorted(by: { $0.key < $1.key }) {
			guard let row = rows[id], row.isOurs else {
				outcome.skipped.append(rows[id]?.label ?? "\(id) not listed")
				continue
			}
			try await account.delete(id)
			try ledger.record(deletedActivity: externalID)
			outcome.deleted.append(id)
		}
		try await clearSeededWellness(into: &outcome)
		let remaining = try await account.activities(
			oldest: today.adding(days: -Self.guardDays), newest: today
		).filter(\.isOurs)
		guard remaining.isEmpty else {
			throw LiveCheckStop(
				description:
					"The account still lists seeded activities after unseeding: "
					+ remaining.map(\.label).joined(separator: "; "))
		}
		if ledgerOnDisk {
			try ledger.retire(as: retiredName)
		}
		return outcome
	}

	private func stillOnAccount(_ id: String, listed: Set<String>) async throws -> Bool {
		if listed.contains(id) { return true }
		return try await account.activityExists(id)
	}

	private func confirmAccount(listing: [SeedListing]) async throws -> String {
		let athlete = try await account.athleteID()
		if let recorded = ledger.athlete {
			guard recorded == athlete else {
				throw LiveCheckStop(
					description:
						"Nothing was changed: the seed ledger belongs to athlete \(recorded), but the key belongs to athlete \(athlete)."
				)
			}
			return athlete
		}
		let listed = Set(listing.map(\.id))
		let unlisted = ledger.activityIDs.filter { !listed.contains($0) }
		guard unlisted.isEmpty else {
			throw LiveCheckStop(
				description:
					"Nothing was changed: the seed ledger names no athlete, and athlete \(athlete) does not list its activities "
					+ unlisted.joined(separator: ", "))
		}
		guard !ledger.activities.isEmpty || ledger.wellness.isEmpty else {
			throw LiveCheckStop(
				description:
					"Nothing was changed: the seed ledger names no athlete and no activity, so its wellness days cannot be tied to athlete \(athlete)."
			)
		}
		return athlete
	}

	private func clearSeededWellness(into outcome: inout UnseedOutcome) async throws {
		guard let oldest = ledger.wellness.keys.min(), let newest = ledger.wellness.keys.max()
		else { return }
		guard let anchor = ledger.anchor else {
			throw LiveCheckStop(
				description:
					"The seed ledger records wellness but no anchor, so the values the seed wrote are unknown and no wellness was cleared."
			)
		}
		let planned = Dictionary(
			LiveSeedPlan(anchor: anchor).wellness.map { ($0.date, $0) },
			uniquingKeysWith: { first, _ in first })
		let current = try await account.wellness(oldest: oldest, newest: newest)
		for (date, fields) in ledger.wellness.sorted(by: { $0.key < $1.key }) {
			let values = current[date] ?? [:]
			for field in fields where values[field] != nil {
				if planned[date]?.holds(values, at: field) == true {
					outcome.cleared[date, default: []].append(field)
				} else {
					outcome.changedSinceSeed.append("\(date.rawValue) \(field)")
				}
			}
		}
		guard !outcome.cleared.isEmpty else { return }
		try await account.writeWellness(
			outcome.cleared.mapValues { fields in
				Dictionary(uniqueKeysWithValues: fields.map { ($0, Double?.none) })
			})
		let after = try await account.wellness(oldest: oldest, newest: newest)
		let stayed = outcome.cleared.sorted { $0.key < $1.key }.flatMap { date, fields in
			fields.filter { after[date]?[$0] != nil }.map { "\(date.rawValue) \($0)" }
		}
		guard stayed.isEmpty else {
			throw LiveCheckStop(
				description:
					"The account still holds seeded wellness after clearing it: "
					+ stayed.joined(separator: ", "))
		}
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
