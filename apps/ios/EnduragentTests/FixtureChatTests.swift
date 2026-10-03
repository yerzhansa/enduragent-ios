import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func sendClearsDraftOnAccepted() async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:slow"
		model.draftChanged(from: "")
		let draftId = model.draft.id
		#expect(model.drafts.load(.main)?.text == "fixture:slow")
		await model.send()
		#expect(model.draft.text.isEmpty)
		#expect(model.draft.id != draftId)
		#expect(model.drafts.load(.main) == nil)
		#expect(!model.notSent)
		let turn = try await firstTurn(model)
		#expect(turn.athleteText == "fixture:slow")
		#expect(!turn.state.isSettled)
		#expect(model.isWorking)
		#expect(services.fixtureTransport?.requestCount == 0)
		let settled = try await settledTurn(model)
		#expect(replyText(settled.state) == FirstWeekFixture.weekSummary)
		#expect(!model.isWorking)
	}

	@Test func sendIsDisabledWhileTheMessageIsBeingAccepted() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = await model(services)
		await model.agreeAndStartChatting()
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

	@Test func textTypedWhileTheMessageIsBeingAcceptedStaysInTheComposer() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.draft.text = TutorialCopy.weekQuestion
		model.draftChanged(from: "")
		let sending = Task { await model.send() }
		await Task.yield()
		try #require(model.isSending)
		let typed = "And on Sunday?"
		model.draft.text = typed
		model.draftChanged(from: TutorialCopy.weekQuestion)
		await sending.value
		#expect(model.draft.text == typed)
		#expect(model.drafts.load(.main) == model.draft)
		#expect(try await settledTurn(model, at: 0).athleteText == TutorialCopy.weekQuestion)
		await model.send()
		#expect(try await settledTurn(model, at: 1).athleteText == typed)
		#expect(model.draft.text.isEmpty)
	}

	@Test func sendKeepsDraftWhenAcceptFails() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let records = try #require(services.fixtureRecordFaults)
		let model = await model(services)
		await model.agreeAndStartChatting()
		records.failNextAppend = true
		model.draft.text = TutorialCopy.weekQuestion
		model.draftChanged(from: "")
		let draft = model.draft
		await model.send()
		#expect(model.notSent)
		#expect(model.draft == draft)
		#expect(model.drafts.load(.main) == draft)
		#expect(model.chat?.turns.isEmpty ?? true)
		#expect(transport.requestCount == 0)
		#expect(!records.failNextAppend)
		#expect(await firstSnapshot(services, chat: .main)?.turns.isEmpty == true)
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
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:fail finish"
		await model.send()
		let turn = try await settledTurn(model)
		guard case .failed(let failed) = turn.state else {
			Issue.record("expected a failed turn, got \(turn.state)")
			return
		}
		#expect(failed.notice.key == Catalog.chatNoticeResponseFailure)
		#expect(failed.notice.action == .tryAgain(turn.id))
	}

	@Test func keepStoreReopensAnUnstartedTurnAsAwaitingRestart() async throws {
		var held = launch
		held.coalescing = CoalescingPolicy(window: .seconds(60))
		let accepted: TurnView
		do {
			let first = await model(try fixtureServices(held, defaults: defaults))
			await first.agreeAndStartChatting()
			first.draft.text = "fixture:hang"
			await first.send()
			accepted = try await firstTurn(first)
		}
		let (second, _) = try await relaunch(.keep)
		let reopened = try #require(await firstSnapshot(second, chat: .main))
		#expect(reopened.turns.map(\.id) == [accepted.id])
		#expect(reopened.turns.first?.state == .accepted(.awaitingRestart))

	}

	@Test func slowDirectiveStreamsTheWeekSummaryWordByWord() async throws {
		let services = try services()
		let transport = try #require(services.fixtureTransport)
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:slow"
		await model.send()
		let settled = try await settledTurn(model)
		#expect(transport.requestCount == 1)
		#expect(replyText(settled.state) == FirstWeekFixture.weekSummary)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		#expect(replyText(try await settledTurn(model, at: 1).state) != nil)
	}

	@Test(arguments: [
		"fixture:fail bogus", "fixture:storage fail-everything", "fixture:fail 500 xlots",
	])
	func unknownDirectiveRepliesWithItsDiagnostic(_ text: String) async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.draft.text = text
		await model.send()
		#expect(
			replyText(try await settledTurn(model).state) == "Unknown fixture directive: \(text)")
		#expect(model.draft.text.isEmpty)
		#expect(services.fixtureTransport?.requestCount == 1)
	}

	@Test func plainTextAfterHangDirectiveAnswersNormally() async throws {
		let model = await model(try services())
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:hang"
		await model.send()
		let turn = try await firstTurn(model)
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while model.services.fixtureTransport?.requestCount == 0, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		await model.stop()
		let stopped = try await settledTurn(model)
		await model.perform(.tryAgain(turn.id))
		#expect(
			replyText(try await settledTurn(model, after: stopped.state).state)
				== FirstWeekFixture.weekSummary)
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		#expect(
			replyText(try await settledTurn(model, at: 1).state) == FirstWeekFixture.weekSummary)
	}

	@Test func queuedRequestsKeepTheirOwnReplies() async throws {
		var launch = launch
		launch.coalescing = CoalescingPolicy(window: .milliseconds(100))
		let services = try fixtureServices(launch, defaults: defaults)
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:slow"
		await model.send()
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while services.fixtureTransport?.requestCount == 0, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(20))
		}
		model.draft.text = "Remember that Saturdays are group rides"
		await model.send()
		try await until {
			model.chat?.turns.last?.state == .accepted(.queued(position: 2))
		}
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		try await until {
			model.chat?.turns.last?.state == .accepted(.queued(position: 3))
		}
		#expect(
			replyText(try await settledTurn(model, at: 1).state) == FirstWeekFixture.rememberReply)
		#expect(
			replyText(try await settledTurn(model, at: 2).state) == FirstWeekFixture.weekSummary)
	}
}
