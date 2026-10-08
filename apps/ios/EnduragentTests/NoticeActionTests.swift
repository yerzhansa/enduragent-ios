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
		let action = try #require(notice.actions.first)
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
		#expect(notice.actions == [.chooseAccessMethod])
		await model.perform(.chooseAccessMethod)
		#expect(model.route == .chat)
		#expect(model.navigation == [.accessMethod])
	}

	@Test func rejectedOpenRouterStartsSignInWithoutOpeningSettings() async throws {
		var launch = launch
		launch.accessMethod = .rejectedOpenRouter
		launch.signInOutcome = .success
		let model = await model(try fixtureServices(launch, defaults: defaults))
		await model.agreeAndStartChatting()
		model.draft.text = "Recover this connection"
		await model.send()
		let turn = try await settledTurn(model)
		guard case .failed(let failed) = turn.state else {
			Issue.record("Expected the rejected connection to fail the turn")
			return
		}
		#expect(failed.notice == nil)
		try await model.waitForStatus { $0.access.attention == .rejectedKey }
		await model.perform(try #require(model.status.access.notice?.actions.first))
		try await model.waitForStatus { $0.access.attention == nil }
		#expect(model.route == .chat)
		#expect(model.navigation.isEmpty)
		#expect(model.chat?.turns.first?.id == turn.id)
		let fixture = try #require(model.services.fixture)
		#expect(await fixture.openRouterAuthorizer.requests.count == 1)
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
