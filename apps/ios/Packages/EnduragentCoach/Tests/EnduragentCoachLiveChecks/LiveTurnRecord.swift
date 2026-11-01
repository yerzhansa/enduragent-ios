import Foundation

@testable import EnduragentCoach

struct LiveTurnRecord: Sendable {
	let message: String
	let exchanges: [LiveExchange]
	let reply: String?
	let outcome: String
	let reviewPending: Bool
	let calendarWrites: Int
	var reviewBefore: WorkoutReview?
	var reviewAfter: WorkoutReview?
	var notice: CatalogKey?
	var plans: [PlanCard] = []
	var draft: JSONValue?
	var prepared: PlanDocument?
	var savedBefore: PlanDocument?
	var savedAfter: PlanDocument?
	var tap: LivePlanTap?
	var approval: LiveApprovalRecord?

	var chat: [LiveExchange] {
		exchanges.filter { [.chatAttempt, .stepRecovery].contains($0.request.charge) }
	}

	var toolCalls: [WireToolCall] {
		chat.flatMap { exchange in
			exchange.events.compactMap { event -> WireToolCall? in
				guard case .toolCall(let call) = event else { return nil }
				return call
			}
		}
	}

	var offeredTools: Set<String> {
		Set(chat.flatMap { $0.request.tools.map(\.name.rawValue) })
	}

	var toolResults: [String: String] {
		var results: [String: String] = [:]
		for message in chat.flatMap(\.request.messages) where message.role == .tool {
			if let id = message.toolCallId { results[id] = message.content }
		}
		return results
	}

	var systemPrompt: String {
		chat.first?.request.messages.first { $0.role == .system }?.content ?? ""
	}

	var athleteMessage: String? {
		chat.first?.request.messages.last { $0.role == .user }?.content
			.components(separatedBy: "\nCurrent time:").first
	}
}
