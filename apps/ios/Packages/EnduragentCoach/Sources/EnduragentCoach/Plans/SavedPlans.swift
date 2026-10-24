import Foundation

struct SavedPlans: Sendable, Equatable {
	static let kind: SyncedKind = .savedPlan
	static let heading = "## Current Plan"
	static let noPlan = "No plan saved yet."
	static let noPlanContext = heading + "\n" + noPlan

	fileprivate let saves: [SavedPlanEntry]

	init(owned records: [AthleteRecord]) {
		var seen: Set<SavedPlanID> = []
		var entries: [SavedPlanEntry] = []
		for record in records.sorted(by: { $0.hlc < $1.hlc }) {
			guard case .synced(.savedPlan(let body)) = record.body, seen.insert(body.id).inserted
			else { continue }
			entries.append(SavedPlanEntry(hlc: record.hlc, civilDate: record.civilDate, body: body))
		}
		saves = entries.sorted { ($0.body.decided, $0.hlc) < ($1.body.decided, $1.hlc) }
	}

	var newest: PlanDocument? { saves.last?.document }

	var headline: String? {
		newest.map { ([Self.heading] + $0.headlineLines).joined(separator: "\n") }
	}

	var loadResult: JSONValue {
		newest?.value ?? .object(["message": .string(Self.noPlan)])
	}

	func history(from: CivilDate, to: CivilDate, contains needle: String?) -> [PlanHistoryLine] {
		zip([nil] + saves.map(Optional.some), saves).compactMap { previous, save in
			guard save.civilDate >= from, save.civilDate <= to else { return nil }
			let line = PlanHistoryLine(
				date: save.civilDate, was: previous?.document.text, now: save.document.text)
			guard let needle else { return line }
			let texts = [line.was, line.now].compactMap(\.self)
			return texts.contains { $0.lowercased().contains(needle) } ? line : nil
		}
	}
}

private struct SavedPlanEntry: Sendable, Equatable {
	let hlc: HybridLogicalClock
	let civilDate: CivilDate
	let body: SavedPlanBody

	var document: PlanDocument { body.document }
}

struct PlanHistoryLine: Sendable, Equatable {
	static let label = "save-plan"

	let date: CivilDate
	let was: String?
	let now: String
}
