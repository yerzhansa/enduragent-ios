import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SlashRoutingTests {
	@Test func parseReadsLeadingToken() {
		#expect(SlashRouting.parse("/review deep") == .review)
		#expect(SlashRouting.parse("/status") == .status)
		#expect(SlashRouting.parse("/workout tomorrow") == .workout)
		#expect(SlashRouting.parse("/plan for my gran fondo in June") == .plan)
		#expect(SlashRouting.parse("/plan") == .plan)
		#expect(SlashRouting.parse("/start") == .start)
		#expect(SlashRouting.parse("/language") == .language)
		#expect(SlashRouting.parse("  /language  ") == .language)
		#expect(SlashRouting.parse("/language it") == .language)
		#expect(SlashRouting.parse("hello /review") == nil)
		#expect(SlashRouting.parse("/feedback  the lap table is cut off ") == .feedback)
		#expect(SlashRouting.parse("/version") == .version)
	}

	@Test func feedbackAndVersionOpenScreensAndFeedbackCarriesItsTrimmedText() {
		let typed = "/feedback  the lap table is cut off "
		#expect(SlashRouting.parse(typed)?.route == .screen(.feedback))
		#expect(SlashRouting.argument(of: typed) == "the lap table is cut off")
		#expect(SlashRouting.argument(of: "/feedback") == "")
		#expect(
			SlashRouting.argument(of: " /feedback\nline one\nline two\n") == "line one\nline two")
		#expect(SlashRouting.parse("/version")?.route == .screen(.about))
	}

	@Test func aScreenRouteLeavesAWaitingReviewAndPlanCardAsTheyWere() async throws {
		let turns = ReviewTurns()
		let recording = BatchRecordingLog(inner: turns.store)
		let coach = await makeCoach(
			transport: turns.transport, intervals: turns.intervals, store: recording,
			clock: HeldClock(calendar: turns.clock))
		_ = try await turns.committed(ReviewTurns.oneRide, on: coach)
		turns.script([
			.toolCall(
				name: "plan_save",
				arguments: canonicalJSON(.object(["plan": PlanTurns.threshold]))),
			.finish(reason: .toolCalls), .text("Saved?"), .finish(reason: .stop),
		])
		#expect(replyText(try await coach.sendAndSettle("Save my plan")) == "Saved?")
		let saved = try #require(await coach.currentSnapshot(.main))
		let card = try #require(saved.plans.last)
		#expect(await coach.decide(.presented(card.ref), in: .main) == .presented)
		let waiting = try #require(await coach.currentSnapshot(.main))
		try #require(waiting.review != nil)
		try #require(PlanTurns.token(of: waiting.plans.last) != nil)
		let batches = recording.batches
		let requests = turns.transport.requestCount

		try await expectScreenRoutes(on: coach)

		#expect(recording.batches == batches)
		#expect(turns.transport.requestCount == requests)
		#expect(await coach.currentSnapshot(.main) == waiting)
	}

	@Test func aScreenRouteLeavesTheCoalescingWindowOpen() async throws {
		let timer = HeldClock()
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence([
			.text("Thursday reply."), .finish(reason: .stop),
		])
		let recording = BatchRecordingLog(inner: InMemoryRecordLog())
		let coach = await makeCoach(
			transport: transport, store: recording, clock: timer, coalescing: .npm,
			coalescingClock: timer)
		let thursday = try #require(
			try await coach.send(draft("Thursday"), to: .main).acceptedTurn)
		try await timer.waitUntilHeld(.milliseconds(1_500))
		let batches = recording.batches
		let collecting = try #require(await coach.currentSnapshot(.main))
		#expect(
			collecting.turns.map(\.state) == [
				.accepted(.collecting(until: timer.now.addingTimeInterval(1.5)))
			])

		try await expectScreenRoutes(on: coach)

		#expect(recording.batches == batches)
		#expect(transport.requestCount == 0)
		#expect(await coach.currentSnapshot(.main) == collecting)
		#expect(timer.held == [.milliseconds(1_500)])
		timer.advance(by: .milliseconds(1_500))
		#expect(
			replyText(try #require(await coach.settledState(of: thursday, in: .main)))
				== "Thursday reply.")
		let settled = try #require(await coach.currentSnapshot(.main))
		#expect(settled.turns.map(\.athleteText) == ["Thursday"])
		#expect(transport.requestCount == 1)
		#expect(
			transport.requests.first?.messages.last?.unstampedContent.hasPrefix(
				"Thursday\nCurrent time: ") == true)
	}

	private func expectScreenRoutes(on coach: Coach) async throws {
		#expect(
			try await coach.send(draft("/feedback text"), to: .main)
				== .openScreen(.feedback, argument: "text"))
		#expect(
			try await coach.send(draft("/version"), to: .main) == .openScreen(.about, argument: ""))
	}

	@Test(arguments: LanguageTag.allCases)
	func welcomeAdvertisesOnlySupportedCommands(tag: LanguageTag) {
		let phrasebook = CatalogPhrasebook(tag: tag)
		let text = Welcome.text(in: phrasebook)
		let advertised = text.matches(of: /\/[a-z]+/).map { String($0.output) }
		#expect(advertised.count == SlashCommand.allCases.count)
		for command in advertised {
			#expect(SlashRouting.parse(command) != nil)
		}
		#expect(Set(advertised.compactMap(SlashRouting.parse)) == Set(SlashCommand.allCases))
		for command in SlashCommand.allCases {
			#expect(text.contains(phrasebook.say(command.menuTitle)))
		}
	}

	@Test(arguments: LanguageTag.allCases)
	func welcomeListsPlanAfterWorkoutWithItsTitle(tag: LanguageTag) throws {
		let phrasebook = CatalogPhrasebook(tag: tag)
		let lines = Welcome.text(in: phrasebook).split(separator: "\n").map(String.init)
		let title = phrasebook.say(Catalog.telegramMenuPlan)
		let workout = try #require(lines.firstIndex { $0.hasPrefix("/workout") })

		#expect(
			lines.dropFirst(workout + 1).first
				== phrasebook.say(
					Catalog.chatWelcomeCommand, ["command": "/plan", "description": title]))
		#expect(!title.isEmpty)
		#expect(
			tag == .en ? title == "Generate a training plan" : title != "Generate a training plan")
	}

	@Test func startRoutesToResetAndPlanIsAModelTurn() async throws {
		#expect(SlashRouting.parse("/start")?.route == .resetConversation)
		#expect(SlashRouting.parse("/language")?.route == .languagePicker)
		#expect(SlashRouting.parse("/review")?.route == .modelTurn)
		#expect(SlashRouting.parse("/plan for my gran fondo in June")?.route == .modelTurn)
		let transport = FakeModelTransport()
		let store = InMemoryRecordLog()
		let coach = await makeCoach(transport: transport, store: store)
		transport.respond = ScriptedReply.sequence(
			[.text("Tell me your FTP and weekly hours."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		let plan = try await coach.sendAndSettle("/plan for my gran fondo in June")
		#expect(replyText(plan) == "Tell me your FTP and weekly hours.")
		#expect(sent(.chatAttempt, by: transport).count == 1)
		let started = try await coach.send(draft("/start"), to: .main)
		guard case .newConversation(let admission) = started else {
			Issue.record("Expected reset admission")
			return
		}
		#expect(await coach.resetCompletion(admission, in: .main) == .started(memory: .saved))
		#expect(sent(.chatAttempt, by: transport).count == 1)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening.notice == Catalog.chatNoticeNewConversationSuccess)
		let messages = try await store.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(messages.map(messageText) == ["/plan for my gran fondo in June"])
		#expect(
			messages.allSatisfy {
				guard case .synced(.userMessage(let body)) = $0.body else { return false }
				return body.slash == .plan
			})
	}
}
