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

	@Test func trimDropsOldestAndKeepsAtLeastOne() {
		let messages = (0..<20).map { index in
			ChatMessage(
				role: index.isMultiple(of: 2) ? .user : .assistant,
				text: String(repeating: "x", count: 8_000))
		}
		let result = HistoryWindow.trim(messages: messages, systemTokens: 1_000, ratio: 0.3)
		#expect(!result.kept.isEmpty)
		#expect(result.kept.count + result.dropped.count == messages.count)
		#expect(result.dropped.count >= 1)
		#expect(result.kept.last == messages.last)
	}

	@Test func trimKeepsWholeTurns() {
		let budget = HistoryWindow.historyTokenBudget(
			systemTokens: 1_000, window: TurnPolicy.contextWindowCap, ratio: 0.3)
		func message(_ role: ChatMessage.Role, tokens: Int) -> ChatMessage {
			ChatMessage(role: role, text: String(repeating: "x", count: tokens * 10 / 3))
		}
		let messages = [
			message(.user, tokens: budget / 2), message(.assistant, tokens: budget / 4),
			message(.user, tokens: budget / 4), message(.assistant, tokens: budget / 4),
		]
		let result = HistoryWindow.trim(messages: messages, systemTokens: 1_000, ratio: 0.3)
		#expect(result.dropped == Array(messages.prefix(2)))
		#expect(result.kept == Array(messages.suffix(2)))
	}

	@Test func trimUsesTheRatioItIsGiven() {
		let messages = (0..<20).map { index in
			ChatMessage(
				role: index.isMultiple(of: 2) ? .user : .assistant,
				text: String(repeating: "x", count: 8_000))
		}
		let narrow = HistoryWindow.trim(messages: messages, systemTokens: 1_000, ratio: 0.3)
		let wide = HistoryWindow.trim(messages: messages, systemTokens: 1_000, ratio: 0.6)
		#expect(wide.budget > narrow.budget)
		#expect(wide.dropped.isEmpty)
		#expect(!narrow.dropped.isEmpty)
	}
}
