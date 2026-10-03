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

	@Test(arguments: ["fixture:fail 402", "fixture:fail 401"])
	func creditsNoticeReturnsToConversationAfterOneBack(directive: String) async throws {
		let model = await model(try services())
		let (_, notice) = try await failedNotice(model, after: directive)
		let action = try #require(notice.action)
		#expect(model.navigation.isEmpty)
		await model.perform(action)
		#expect(model.navigation == [.credits])
		await model.loadCredits()
		try #require(model.navigation.last == .credits)
		model.navigation.removeLast()
		#expect(model.navigation.isEmpty)
		#expect(model.route == .chat)
		#expect(model.chat?.turns.last?.state.isSettled == true)
	}

	@Test(arguments: [FixtureKeychainPolicy.empty, .unavailable, .malformedAccess])
	func notConfiguredStorageUnavailableAndMalformedOpenAccessMethod(
		keychain: FixtureKeychainPolicy
	) async throws {
		let model = await model(try services(keychain: keychain))
		let (_, notice) = try await failedNotice(model, after: "Hello")
		let expected =
			switch keychain {
			case .unavailable: Catalog.accessErrorStorageUnavailable
			case .malformedAccess: Catalog.accessErrorMalformed
			default: Catalog.accessErrorNotConfigured
			}
		#expect(notice.key == expected)
		#expect(notice.action == .chooseAccessMethod)
		await model.perform(.chooseAccessMethod)
		#expect(model.route == .chat)
		#expect(model.navigation == [.accessMethod])
	}

	@Test func signInToOpenRouterOpensAccessMethod() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.open(.settings)
		let previous = model.status.access
		await model.perform(.signInToOpenRouter)
		#expect(model.route == .chat)
		#expect(model.navigation == [.settings, .accessMethod])
		#expect(model.status.access == previous)
	}

	@Test func lockedKeychainKeepsTheMessageAndOffersTryAgain() async throws {
		let model = await model(try services(keychain: .locked))
		let (turn, notice) = try await failedNotice(model, after: "Hello")
		#expect(notice.key == Catalog.accessErrorLocked)
		#expect(notice.action == .tryAgain(turn.id))
		#expect(turn.athleteText == "Hello")
	}

	@Test func aRateLimitOffersTryAgainWhenItsWaitEnds() async throws {
		let model = await model(try services())
		let (turn, waiting) = try await failedNotice(model, after: "fixture:fail 429 2 x4")
		#expect(waiting.action == .wait(thenTryAgain: turn.id))
		let opened = try await settledTurn(model, after: turn.state, within: .hangGuard)
		#expect(notice(ofFailed: opened.state)?.action == .tryAgain(turn.id))
		await model.perform(.tryAgain(turn.id))
		let retried = try await settledTurn(model, after: opened.state)
		#expect(retried.id == turn.id)
		#expect(replyText(retried.state) == FirstWeekFixture.weekSummary)
	}
}
