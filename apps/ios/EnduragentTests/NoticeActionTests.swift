import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

private func notice(ofFailed state: TurnState) -> AthleteNotice? {
	guard case .failed(let failed) = state else { return nil }
	return failed.notice
}

extension FixtureLaunchTests {
	func failedNotice(_ model: ShellModel, after text: String) async throws -> (
		TurnView, AthleteNotice
	) {
		await model.agreeAndStartChatting()
		model.draft.text = text
		await model.send()
		let turn = try await settledTurn(model)
		return (turn, try #require(notice(ofFailed: turn.state)))
	}

	@Test func outOfCreditsNoticeReturnsToConversationAfterOneBack() async throws {
		let model = await model(try services())
		let (_, notice) = try await failedNotice(model, after: "fixture:fail 402")
		#expect(notice.actions == [.buyCredits])
		#expect(model.navigation.isEmpty)
		await model.perform(.buyCredits)
		try #require(model.navigation == [.credits])
		model.navigation.removeLast()
		#expect(model.navigation.isEmpty)
		#expect(model.route == .chat)
		#expect(model.chat?.turns.last?.state.isSettled == true)
	}

	@Test(arguments: [FixtureKeychainPolicy.empty, .unavailable])
	func noCreditsOpensCreditsAndUnavailableStorageOffersTryAgain(
		keychain: FixtureKeychainPolicy
	) async throws {
		let model = await model(try services(keychain: keychain))
		let (turn, notice) = try await failedNotice(model, after: "Hello")
		if keychain == .empty {
			#expect(notice.key == Catalog.accessErrorNotConfigured)
			#expect(notice.actions == [.buyCredits])
			await model.perform(.buyCredits)
			#expect(model.navigation == [.credits])
		} else {
			#expect(notice.key == Catalog.accessErrorStorageUnavailable)
			#expect(notice.actions == [.tryAgain(turn.id)])
		}
		#expect(model.route == .chat)
	}

	@Test func lockedKeychainKeepsTheMessageAndOffersTryAgain() async throws {
		let model = await model(try services(keychain: .locked))
		let (turn, notice) = try await failedNotice(model, after: "Hello")
		#expect(notice.key == Catalog.accessErrorLocked)
		#expect(notice.actions == [.tryAgain(turn.id)])
		#expect(turn.athleteText == "Hello")
	}

	@Test func aRateLimitOffersTryAgainWhenItsWaitEnds() async throws {
		let model = await model(try services())
		let (turn, waiting) = try await failedNotice(model, after: "fixture:fail 429 2 x4")
		#expect(waiting.actions == [.wait(thenTryAgain: turn.id)])
		let opened = try await settledTurn(model, after: turn.state, within: .hangGuard)
		#expect(notice(ofFailed: opened.state)?.actions == [.tryAgain(turn.id)])
		await model.perform(.tryAgain(turn.id))
		let retried = try await settledTurn(model, after: opened.state)
		#expect(retried.id == turn.id)
		#expect(replyText(retried.state) == FirstWeekFixture.weekSummary)
	}
}
