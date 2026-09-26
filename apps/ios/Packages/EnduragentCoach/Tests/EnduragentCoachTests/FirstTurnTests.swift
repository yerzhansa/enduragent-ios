import Testing

@testable import EnduragentCoach

@Suite struct FirstTurnTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	func makeCoach() -> Coach {
		EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)
	}

	@Test func coachStartsWithNoHistory() async throws {
		let coach = makeCoach()
		#expect(await coach.transcript(.main).isEmpty)
	}

	@Test func replyStreamsTextThenFinishes() async throws {
		transport.script = [
			.text("Your week: "), .text("two rides, 3 h 10 min."), .finish(reason: .stop),
		]
		let coach = makeCoach()
		let turn = try #require(
			try await coach.send(draft("What did my week look like?"), to: .main).acceptedTurn)
		var liveTexts: [String] = []
		var settled: TurnState?
		for await snapshot in await coach.observe(.main) {
			guard let state = snapshot.turns.first?.state else { continue }
			if case .processing(let processing) = state {
				liveTexts.append(processing.liveText)
			}
			if state.isSettled {
				settled = state
				break
			}
		}
		#expect(liveTexts.contains("Your week: "))
		#expect(replyText(try #require(settled)) == "Your week: two rides, 3 h 10 min.")
		#expect(await coach.transcript(.main).count == 2)
		#expect(turn == (await coach.currentSnapshot(.main))?.turns.first?.id)

		let request = transport.requests[0]
		#expect(request.stream == true)
		#expect(request.messages.first?.role == .system)
		#expect(request.messages.first?.content.contains("=== BEGIN ATHLETE DATA") == true)
		#expect(request.messages.last?.content.contains("Current time:") == true)
		#expect(request.messages.last?.content.contains("1998-06-13") == true)
		#expect(request.tools.map(\.name.rawValue).contains("intervals_fetch_activities"))
		#expect(request.messages.first?.content.hasPrefix("# Cycling Coach") == true)
	}

	@Test func providerErrorFinishWithTextPersistsTheReply() async throws {
		transport.script = [.text("Tomorrow's ride is queued."), .finish(reason: .error)]
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("Give me a ride for tomorrow")
		#expect(replyText(settled) == "Tomorrow's ride is queued.")
		#expect(
			await coach.transcript(.main) == [
				"Give me a ride for tomorrow",
				"Tomorrow's ride is queued.",
			])
	}

	@Test func providerContentFilterFinishWithTextPersistsTheReply() async throws {
		transport.script = [.text("Tomorrow's ride is queued."), .finish(reason: .contentFilter)]
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("Give me a ride for tomorrow")
		#expect(replyText(settled) == "Tomorrow's ride is queued.")
	}

	@Test func emptyProviderErrorFinishFailsWithoutAReply() async throws {
		transport.script = [.finish(reason: .error)]
		let coach = makeCoach()
		let settled = try await coach.sendAndSettle("Give me a ride for tomorrow")
		#expect(failure(settled) == .model(.generationFailed(.emptyAfterError)))
		guard case .failed(let failed) = settled else { return }
		#expect(failed.notice.key == Catalog.chatNoticeResponseFailure)
		#expect(await coach.transcript(.main) == ["Give me a ride for tomorrow"])
		let replies = try await store.fetch(
			RecordQuery(scope: .synced([.turnSettled]), chatId: .main)
		)
		.records
		#expect(replies.count == 1)
	}

	@Test func toolCallRunsAndFeedsBackIntoTheTurn() async throws {
		intervals.activities = [
			.ride(name: "Sunday long ride", date: "1998-06-07", durationS: 7200, trainingLoad: 120)
		]
		transport.script = [
			.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#),
			.finish(reason: .toolCalls),
			.text("Sunday long ride, 2 h, load 120."),
			.finish(reason: .stop),
		]
		let coach = makeCoach()
		let turn = try #require(
			try await coach.send(draft("Review my last ride"), to: .main).acceptedTurn)
		var activities: [TurnActivity] = []
		for await snapshot in await coach.observe(.main) {
			guard let state = snapshot.turns.first?.state else { continue }
			if case .processing(let processing) = state, activities.last != processing.activity {
				activities.append(processing.activity)
			}
			if state.isSettled { break }
		}
		#expect(activities.contains(.runningTools([.intervalsFetchActivities])))
		#expect(transport.requests.count == 2)
		#expect(
			intervals.calls == [
				.wellness(oldest: "1998-06-07", newest: "1998-06-13"),
				.activities(days: 7),
			]
		)
		#expect(
			replyText(try #require(await coach.settledState(of: turn, in: .main)))
				== "Sunday long ride, 2 h, load 120.")
	}

	@Test func memoryIsWrittenAfterTheReplyAndQueryable() async throws {
		transport.script = [
			.text("Noted: group ride on Saturdays."), .finish(reason: .stop),
			.toolCall(
				name: "ledger_append",
				arguments:
					#"{"kind":"decision","date":"1998-06-13","text":"Rides with a group on Saturdays"}"#
			),
			.finish(reason: .toolCalls), .finish(reason: .stop),
		]
		let coach = makeCoach()
		_ = try await coach.sendAndSettle("Remember that I ride with a group on Saturdays")
		await coach.waitForMemoryFlush()

		let hits = try await coach.memory.query(
			from: "1998-06-01", to: "1998-06-30", contains: "Saturdays")
		let hit = try #require(hits.first)
		#expect(hits.count == 1)
		#expect(hit.date == "1998-06-13")
		#expect(hit.kind == .ledger(.decision))
	}

	@Test func calendarWriteBecomesAPendingProposal() async throws {
		transport.script = [
			.toolCall(name: "intervals_create_workout", arguments: workoutArguments),
			.finish(reason: .toolCalls),
			.text("I've prepared the ride. Confirm to add it."),
			.finish(reason: .stop),
		]
		let coach = makeCoach()
		let pending = try await proposeEnduranceRide(coach)
		#expect(pending.chatId == "main")
		#expect(pending.summary == "Create workout \"Endurance\" on 1998-06-14")
		#expect(pending.description.hasPrefix("Warmup\n- 10m 55-65%"))
		#expect(pending.expiresAt == clock.now.addingTimeInterval(10 * 60))
		#expect(
			!intervals.calls.contains { call in
				if case .createEvent = call { return true }
				return false
			}
		)
		#expect(await coach.pendingProposal(chatId: "main")?.nonce == pending.nonce)
	}

	@Test func calendarProposalSurvivesProviderErrorFinish() async throws {
		transport.script = [
			.toolCall(name: "intervals_create_workout", arguments: workoutArguments),
			.finish(reason: .toolCalls),
			.text("I've prepared the ride. Confirm to add it."),
			.finish(reason: .error),
		]
		let coach = makeCoach()
		let pending = try await proposeEnduranceRide(coach)
		#expect(pending.summary == "Create workout \"Endurance\" on 1998-06-14")
		#expect(
			await coach.transcript(.main).contains("I've prepared the ride. Confirm to add it."))
		#expect(await coach.pendingProposal(chatId: "main") != nil)
	}

	@Test func confirmRunsTheWriteOnceAndClearsTheSnapshotProposal() async throws {
		let coach = makeCoach()
		let pending = try await proposeEnduranceRide(coach)

		let outcome = try await coach.confirm(chatId: "main", nonce: pending.nonce)

		#expect(outcome == .executed(summary: "Create workout \"Endurance\" on 1998-06-14"))
		#expect(
			intervals.calls.last
				== .createEvent(
					date: "1998-06-14", externalId: "cycling-coach:1998-06-14:endurance"))
		#expect(await coach.pendingProposal(chatId: "main") == nil)
		for await snapshot in await coach.observe(.main) where snapshot.pendingProposal == nil {
			break
		}

		let again = try await coach.confirm(chatId: "main", nonce: pending.nonce)
		#expect(again == .none)
	}

	var workoutArguments: String {
		#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}},{"type":"steady","duration":{"value":70,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}},{"type":"cooldown","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}}]}}"#
	}

	func proposeEnduranceRide(_ coach: Coach) async throws -> PendingProposal {
		if transport.script.isEmpty {
			transport.script = [
				.toolCall(name: "intervals_create_workout", arguments: workoutArguments),
				.finish(reason: .toolCalls),
				.text("I've prepared the ride. Confirm to add it."),
				.finish(reason: .stop),
			]
		}
		let turn = try #require(
			try await coach.send(draft("Give me an endurance ride for tomorrow"), to: .main)
				.acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		let snapshot = try #require(await coach.currentSnapshot(.main))
		return try #require(snapshot.pendingProposal)
	}
}
