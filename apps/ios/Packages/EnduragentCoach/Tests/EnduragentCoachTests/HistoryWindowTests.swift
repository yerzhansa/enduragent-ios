import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct HistoryWindowTests {
	@Test func budgetMatchesEstimatorFormula() {
		let budget = HistoryWindow.historyTokenBudget(
			systemTokens: 4_000, window: 200_000, ratio: 0.3)
		#expect(
			budget
				== max(
					Int((200_000.0 * 0.3).rounded(.down)) - 4_000 - 20_000,
					TurnPolicy.historyBudgetFloor))
		let small = HistoryWindow.historyTokenBudget(
			systemTokens: 80_000, window: 200_000, ratio: 0.3)
		#expect(small == TurnPolicy.historyBudgetFloor)
	}

	@Test func trimKeepsWholeTurns() {
		let budget = HistoryWindow.historyTokenBudget(
			systemTokens: 1_000, window: TurnPolicy.contextWindowCap, ratio: 0.3)
		func message(_ role: WireMessage.Role, tokens: Int) -> WireMessage {
			WireMessage(
				role: role, content: String(repeating: "x", count: tokens * 10 / 3), toolCalls: [],
				toolCallId: nil)
		}
		let messages = [
			message(.user, tokens: budget / 2), message(.assistant, tokens: budget / 4),
			message(.user, tokens: budget / 4), message(.assistant, tokens: budget / 4),
		]
		let result = HistoryWindow.trim(messages: messages, systemTokens: 1_000, ratio: 0.3)
		#expect(result.dropped == Array(messages.prefix(2)))
		#expect(result.kept == Array(messages.suffix(2)))
	}
}
