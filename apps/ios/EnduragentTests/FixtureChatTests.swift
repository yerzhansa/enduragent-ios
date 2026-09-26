import EnduragentCoach
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func sendClearsDraftOnAccepted() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:slow"
		model.draftChanged(from: "")
		let draftId = model.draft.id
		#expect(model.drafts.load(model.chatId)?.text == "fixture:slow")
		await model.send()
		#expect(model.draft.text.isEmpty)
		#expect(model.draft.id != draftId)
		#expect(model.drafts.load(model.chatId) == nil)
		#expect(!model.notSent)
		let turn = try await firstTurn(model)
		#expect(turn.athleteText == "fixture:slow")
		#expect(!isSettled(turn.state))
		#expect(model.isWorking)
		#expect(services.fixtureTransport?.requestCount == 0)
		let settled = try await settledTurn(model)
		#expect(replyText(settled.state) == FirstWeekFixture.weekSummary)
		#expect(!model.isWorking)
	}

	@Test func sendIsDisabledWhileTheMessageIsBeingAccepted() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		model.draft.text = TutorialCopy.weekQuestion
		#expect(!model.isSending)
		let first = Task { await model.send() }
		await Task.yield()
		#expect(model.isSending)
		await model.send()
		await first.value
		#expect(!model.isSending)
		#expect(replyText(try await settledTurn(model).state) != nil)
		#expect(model.chat?.turns.count == 1)
		#expect(transport.requestCount == 1)
	}

	@Test func sendKeepsDraftWhenAcceptFails() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let records = try #require(services.fixtureRecordLog)
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:storage fail-next-append"
		model.draftChanged(from: "")
		let draft = model.draft
		await model.send()
		#expect(model.notSent)
		#expect(model.draft == draft)
		#expect(model.drafts.load(model.chatId) == draft)
		#expect(model.chat?.turns.isEmpty ?? true)
		#expect(transport.requestCount == 0)
		#expect(!records.failNextAppend)
		#expect(await firstSnapshot(services, chat: model.chatId)?.turns.isEmpty == true)
		model.draft.text = TutorialCopy.weekQuestion
		model.draftChanged(from: draft.text)
		#expect(model.draft.id == draft.id)
		await model.send()
		#expect(!model.notSent)
		#expect(model.draft.text.isEmpty)
		#expect(try await firstTurn(model).athleteText == TutorialCopy.weekQuestion)
		#expect(replyText(try await settledTurn(model).state) != nil)
	}

	@Test func unknownFinishReasonDoesNotShowSwiftErrorDump() async throws {
		let model = model(try services())
		model.startChatting()
		model.draft.text = "fixture:fail finish"
		await model.send()
		let turn = try await settledTurn(model)
		guard case .failed(let failed) = turn.state else {
			Issue.record("expected a failed turn, got \(turn.state)")
			return
		}
		#expect(failed.notice.key == Catalog.chatNoticeResponseFailure)
		#expect(failed.notice.action == .tryAgain(turn.id))
		#expect(model.errorLine == nil)
	}

	@Test func keepStoreReopensAnUnstartedTurnAsAwaitingRestart() async throws {
		var held = launch
		held.coalescing = CoalescingPolicy(window: .seconds(60))
		let first = model(try AppServices.fixture(held, defaults: defaults))
		first.startChatting()
		first.draft.text = "fixture:hang"
		await first.send()
		let accepted = try await firstTurn(first)
		let (second, _) = try relaunch(.keep)
		let reopened = try #require(await firstSnapshot(second, chat: first.chatId))
		#expect(reopened.turns.map(\.id) == [accepted.id])
		#expect(reopened.turns.first?.state == .accepted(.awaitingRestart))
		await first.stop()
		guard case .interrupted(let stopped) = try await settledTurn(first).state else {
			Issue.record("expected the held turn to stop before it started")
			return
		}
		#expect(stopped.cause == .stoppedBeforeStart)
	}

	@Test func slowDirectiveStreamsTheWeekSummaryWordByWord() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:slow"
		await model.send()
		let settled = try await settledTurn(model)
		#expect(transport.requestCount == 1)
		#expect(replyText(settled.state) == FirstWeekFixture.weekSummary)
		#expect(transport.requestDelay == FixtureDirector.slowFirstWordDelay)
		#expect(transport.deltaDelay == FixtureDirector.slowWordDelay)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		#expect(transport.requestDelay == nil)
		#expect(transport.deltaDelay == nil)
		#expect(replyText(try await settledTurn(model, at: 1).state) != nil)
	}

	@Test func providerFailureNoticeCarriesNoServerBody() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		model.draft.text = "Give me a ride for tomorrow"
		await model.send()
		transport.failures = [
			.http(status: 500, body: #"{"error":{"message":"upstream exploded at 10.0.0.7"}}"#)
		]
		let turn = try await settledTurn(model)
		guard case .failed(let failed) = turn.state else {
			Issue.record("expected a failed turn, got \(turn.state)")
			return
		}
		#expect(failed.notice.key == Catalog.coachErrorProviderDown)
		#expect(failed.notice.vars.isEmpty)
		#expect(failed.notice.action == .tryAgain(turn.id))
		#expect(model.errorLine == nil)
	}

	@Test(arguments: [
		("fixture:fail 401", Catalog.coachErrorProviderCredentials, false),
		("fixture:fail 402", Catalog.coachErrorUnknown, false),
		("fixture:fail 429 7", Catalog.coachErrorRateLimitSeconds, true),
		("fixture:fail network", Catalog.coachErrorProviderDown, true),
		("fixture:fail timeout", Catalog.coachErrorProviderDown, true),
		("fixture:fail overflow", Catalog.coachErrorUnknown, true),
	])
	func failDirectiveSettlesWithItsNotice(directive: String, key: CatalogKey, tryAgain: Bool)
		async throws
	{
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		model.draft.text = directive
		await model.send()
		let failed = try await settledTurn(model)
		guard case .failed(let failure) = failed.state else {
			Issue.record("expected a failed turn, got \(failed.state)")
			return
		}
		#expect(failure.notice.key == key)
		#expect(failure.notice.action == (tryAgain ? .tryAgain(failed.id) : nil))
		#expect(transport.requestCount == 1)
		#expect(model.errorLine == nil)
	}

	@Test func failDirectiveShowsTheProviderDownNoticeWithTryAgain() async throws {
		let services = try services()
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:fail 500"
		await model.send()
		let failed = try await settledTurn(model)
		guard case .failed(let failure) = failed.state else {
			Issue.record("expected a failed turn, got \(failed.state)")
			return
		}
		#expect(failure.notice.key == Catalog.coachErrorProviderDown)
		#expect(failure.notice.action == .tryAgain(failed.id))
		#expect(model.errorLine == nil)
		await model.perform(.tryAgain(failed.id))
		let retried = try await settledTurn(model, after: failed.state)
		#expect(retried.id == failed.id)
		#expect(replyText(retried.state) == FirstWeekFixture.weekSummary)
	}

	@Test func unknownDirectiveIsShownAndSendsNothing() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = model(services)
		model.startChatting()
		model.draft.text = "fixture:fail bogus"
		await model.send()
		#expect(transport.requestCount == 0)
		#expect(model.chat?.turns.isEmpty ?? true)
		#expect(model.draft.text == "fixture:fail bogus")
		#expect(model.errorLine == "Unknown fixture directive: fixture:fail bogus")
		model.draft.text = "fixture:storage fail-everything"
		await model.send()
		#expect(model.errorLine == "Unknown fixture directive: fixture:storage fail-everything")
		#expect(transport.requestCount == 0)
		#expect(await firstSnapshot(services, chat: model.chatId)?.turns.isEmpty == true)
	}

	@Test func nextMessageClearsAQueuedFailure() throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let director = try #require(services.fixtureDirector)
		#expect(director.prepare(for: "fixture:fail 500") == .sendToCoach)
		#expect(transport.failures.count == 1)
		#expect(director.prepare(for: TutorialCopy.weekQuestion) == .sendToCoach)
		#expect(transport.failures.isEmpty)
	}

	@Test func plainTextAfterHangDirectiveAnswersNormally() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let director = try #require(services.fixtureDirector)
		#expect(director.prepare(for: "fixture:hang") == .sendToCoach)
		#expect(transport.hangUntilCancelled)
		#expect(director.prepare(for: TutorialCopy.weekQuestion) == .sendToCoach)
		#expect(!transport.hangUntilCancelled)
		#expect(transport.script == [.text(FirstWeekFixture.weekSummary), .finish(reason: .stop)])
		#expect(director.prepare(for: "fixture:hang") == .sendToCoach)
		director.prepareRetry(of: "fixture:hang")
		#expect(!transport.hangUntilCancelled)
		#expect(transport.script == [.text(FirstWeekFixture.weekSummary), .finish(reason: .stop)])
	}
}
