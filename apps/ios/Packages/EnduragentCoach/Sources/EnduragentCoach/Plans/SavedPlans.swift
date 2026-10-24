import Foundation

struct SavedPlans: Sendable, Equatable {
	static let kind: SyncedKind = .savedPlan

	fileprivate let saves: [SavedPlanEntry]

	init(owned records: [AthleteRecord]) {
		var seen: Set<SavedPlanID> = []
		var entries: [SavedPlanEntry] = []
		for record in records.sorted(by: { $0.hlc < $1.hlc }) {
			guard case .synced(.savedPlan(let body)) = record.body, seen.insert(body.id).inserted
			else { continue }
			entries.append(SavedPlanEntry(hlc: record.hlc, body: body))
		}
		saves = entries.sorted { ($0.body.decided, $0.hlc) < ($1.body.decided, $1.hlc) }
	}

	var newest: PlanDocument? { saves.last?.document }
}

private struct SavedPlanEntry: Sendable, Equatable {
	let hlc: HybridLogicalClock
	let body: SavedPlanBody

	var document: PlanDocument { body.document }
}
