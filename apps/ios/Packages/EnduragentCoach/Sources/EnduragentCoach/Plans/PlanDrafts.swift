import Foundation

struct PlanDraftStructure: Sendable, Equatable {
	private let fields: [String: JSONValue]

	init?(_ outcome: ToolOutcome) {
		guard case .result(let envelope) = outcome,
			let draft = UntrustedEnvelope.data(in: envelope)?.objectFields,
			let weeks = draft["totalWeeks"], weeks.numberValue != nil,
			let phases = draft["phases"], phases.arrayValue != nil,
			let zoneTables = draft["zoneTables"], zoneTables.arrayValue != nil
		else { return nil }
		fields = ["totalWeeks": weeks, "phases": phases, "zoneTables": zoneTables]
	}

	func applied(to arguments: JSONValue) -> JSONValue {
		guard case .object(var call) = arguments, case .object(let plan)? = call["plan"] else {
			return arguments
		}
		call["plan"] = .object(plan.merging(fields) { _, drafted in drafted })
		return .object(call)
	}
}

struct PlanDrafts: Sendable {
	private var running: [DraftKey: PlanDraftStructure] = [:]
	private var finished: [ChatID: (turn: TurnID, draft: PlanDraftStructure)] = [:]

	mutating func record(_ draft: PlanDraftStructure, for key: DraftKey) {
		running[key] = draft
	}

	mutating func settle(_ key: DraftKey, in chat: ChatID, ending: TurnEnding) {
		guard let draft = running.removeValue(forKey: key), ending == .finished else { return }
		finished[chat] = (key.turn, draft)
	}

	func applied(to arguments: JSONValue, for key: DraftKey, in chat: ChatID, ledger: Ledger)
		async throws(LedgerFailure) -> JSONValue
	{
		if let draft = running[key] { return draft.applied(to: arguments) }
		guard let held = finished[chat],
			try await ledger.conversation(chat).current.turns.contains(where: {
				$0.turn == held.turn
			})
		else { return arguments }
		return held.draft.applied(to: arguments)
	}
}
