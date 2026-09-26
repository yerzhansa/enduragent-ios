import EnduragentCoach
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
		model.startChatting()
		model.draft.text = text
		await model.send()
		let turn = try await settledTurn(model)
		return (turn, try #require(notice(ofFailed: turn.state)))
	}

	@Test(arguments: ["fixture:fail 402", "fixture:fail 401"])
	func creditsActionsOpenTheCreditsScreen(directive: String) async throws {
		let model = model(try services())
		let (_, notice) = try await failedNotice(model, after: directive)
		let action = try #require(notice.action)
		#expect(!model.showCredits)
		await model.perform(action)
		#expect(model.showCredits)
		#expect(model.route == .chat)
	}

	@Test func notConfiguredOpensTheConnectStep() async throws {
		let model = model(try services(keychain: .empty))
		let (turn, notice) = try await failedNotice(model, after: "Hello")
		#expect(notice.key == Catalog.accessErrorNotConfigured)
		#expect(notice.action == .chooseAccessMethod)
		#expect(!turn.state.retryable)
		await model.perform(.chooseAccessMethod)
		#expect(model.route == .onboarding(.connect))
		#expect(!model.showCredits)
	}

	@Test func signInToOpenRouterOpensTheConnectStep() async throws {
		let model = model(try services())
		model.startChatting()
		await model.perform(.signInToOpenRouter)
		#expect(model.route == .onboarding(.connect))
	}

	@Test func lockedKeychainKeepsTheMessageAndOffersTryAgain() async throws {
		let model = model(try services(keychain: .locked))
		let (turn, notice) = try await failedNotice(model, after: "Hello")
		#expect(notice.key == Catalog.accessErrorLocked)
		#expect(notice.action == .tryAgain(turn.id))
		#expect(turn.athleteText == "Hello")
	}

	@Test func waitingOutARateLimitTriesTheTurnAgain() async throws {
		let model = model(try services())
		let (turn, notice) = try await failedNotice(model, after: "fixture:fail 429 1 x4")
		let action = try #require(notice.action)
		#expect(action.opensAt != nil)
		await model.perform(action)
		let retried = try await settledTurn(model, after: turn.state)
		#expect(retried.id == turn.id)
		#expect(replyText(retried.state) == FirstWeekFixture.weekSummary)
	}
}
