import Foundation

@testable import EnduragentCoach

enum LivePlanExpectation: Sendable, Equatable {
	case keepsNumbers(ToolName, fields: [String])
	case savesOnce
	case savesDraft
	case claimsNoSave
	case leavesNoCard
	case keepsSavedPlan
	case loadsSaved
}

struct LivePlanTap: Sendable {
	let outcome: String
	let saved: Bool
}

extension LiveTurnRecord {
	func results(of tool: ToolName) -> [JSONValue] {
		let results = toolResults
		return toolCalls.filter { $0.name == tool.rawValue }.compactMap { call in
			results[call.id].flatMap(LivePlanVerdict.data)
		}
	}

	var waitingPlans: [PlanCard] { plans.filter(Self.waiting) }

	static func waiting(_ card: PlanCard) -> Bool {
		guard case .waiting = card.state else { return false }
		return true
	}
}

enum LivePlanVerdict {
	static let save = ToolName.planSave.rawValue
	static let load = ToolName.planLoad.rawValue
	static let draftFields = ["totalWeeks", "phases", "zoneTables"]
	static let saveClaims = [
		"is saved", "has been saved", "have saved", "saved your plan", "plan saved", "now saved",
	]

	static func check(
		_ expectation: LivePlanExpectation, on turn: LiveTurnRecord,
		calls: [LiveVerdict.ParsedCall], reply: String
	) -> String? {
		let saves = calls.filter { $0.name == save }
		switch expectation {
		case .keepsNumbers(let tool, let fields):
			let results = turn.results(of: tool)
			guard !results.isEmpty else { return "\(tool.rawValue) gave no result this turn" }
			let shown = Set(numberTokens(in: reply))
			let problems = results.map { result in
				fields.compactMap { field -> String? in
					let numbers = numbers(at: field, in: result)
					guard !numbers.isEmpty else { return "\(tool.rawValue) gave no \(field)" }
					let dropped = numbers.filter { !shown.contains($0) }
					return dropped.isEmpty
						? nil : "the reply drops \(field) \(dropped.joined(separator: ", "))"
				}
			}
			if problems.contains(where: \.isEmpty) { return nil }
			if let only = problems.first, problems.count == 1 {
				return only.joined(separator: "; ")
			}
			return problems.enumerated().map { index, found in
				"\(tool.rawValue) result \(index + 1): \(found.joined(separator: "; "))"
			}.joined(separator: "; ")
		case .savesOnce:
			guard let only = saves.first, saves.count == 1 else {
				return "\(save) was called \(saves.count) times, not once"
			}
			guard
				turn.toolResults[only.id].flatMap(data)?.objectFields["pendingConfirmation"]
					== .bool(true)
			else { return "\(save) did not answer pendingConfirmation" }
			let waiting = turn.waitingPlans.count
			return waiting == 1 ? nil : "\(waiting) plan cards wait, not one"
		case .savesDraft:
			guard let draft = turn.draft else {
				return "build_plan_skeleton gave no draft before \(save)"
			}
			guard !saves.isEmpty else { return "\(save) was not called" }
			guard let prepared = turn.prepared else {
				return "no waiting plan card holds the plan \(save) prepared"
			}
			let differing = draftFields.filter {
				prepared.value.objectFields[$0] != draft.objectFields[$0]
			}
			if !differing.isEmpty {
				return
					"the plan \(save) prepared differs from the draft in \(differing.joined(separator: ", "))"
			}
			guard turn.tap?.saved == true else { return nil }
			return turn.savedAfter == prepared
				? nil : "the plan Save plan saved differs from the plan \(save) prepared"
		case .claimsNoSave:
			let lowered = reply.lowercased()
			let claims = saveClaims.filter { lowered.contains($0) }
			return claims.isEmpty
				? nil
				: "the reply claims a save: \(claims.map { "\"\($0)\"" }.joined(separator: ", "))"
		case .leavesNoCard:
			if !saves.isEmpty { return "\(save) was called" }
			return turn.plans.isEmpty ? nil : "a plan card is shown"
		case .keepsSavedPlan:
			let problems = [
				saves.isEmpty ? nil : "\(save) was called",
				turn.waitingPlans.isEmpty ? nil : "a plan card waits",
				turn.savedAfter?.digest == turn.savedBefore?.digest
					? nil : "the saved plan changed",
			].compactMap(\.self)
			return problems.isEmpty ? nil : problems.joined(separator: "; ")
		case .loadsSaved:
			guard calls.contains(where: { $0.name == load }) else {
				return "\(load) was not called"
			}
			guard let name = turn.savedAfter?.value.objectFields["name"]?.stringValue else {
				return "no plan is saved"
			}
			return reply.range(of: name, options: .caseInsensitive) == nil
				? "the reply does not hold the saved plan's name \"\(name)\"" : nil
		}
	}

	static func violations(ofTap tap: LivePlanTap?) -> [String] {
		guard let tap else { return ["no plan card waited to save"] }
		return tap.saved ? [] : ["Save plan answered \(tap.outcome)"]
	}

	static func data(_ result: String) -> JSONValue? {
		guard case .success(let value) = Result(catching: { try JSONValue.parse(result) }) else {
			return nil
		}
		return value.objectFields["data"]
	}

	static func numbers(at field: String, in value: JSONValue) -> [String] {
		leaves(at: field.split(separator: ".")[...], in: value).flatMap { leaf -> [String] in
			switch leaf {
			case .number(let number): [JavaScriptNumber.text(number)]
			case .string(let text): numberTokens(in: text)
			case .null, .bool, .array, .object: []
			}
		}
	}

	static func numberTokens(in text: String) -> [String] {
		text.matches(of: /\d+(?:[.,]\d+)*/).map { String($0.output) }
	}

	private static func leaves(at path: ArraySlice<Substring>, in value: JSONValue) -> [JSONValue] {
		if case .array(let items) = value {
			return items.flatMap { leaves(at: path, in: $0) }
		}
		guard let key = path.first else { return [value] }
		guard let field = value.objectFields[String(key)] else { return [] }
		return leaves(at: path.dropFirst(), in: field)
	}
}
