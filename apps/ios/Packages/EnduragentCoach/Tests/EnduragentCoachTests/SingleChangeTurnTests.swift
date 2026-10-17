import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension FirstTurnTests {
	@Test func calendarWriteBecomesAReview() async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "intervals_create_workout", arguments: workoutArguments),
				.finish(reason: .toolCalls),
				.text("I've prepared the ride. Confirm to add it."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		let review = try await proposeEnduranceRide(coach)
		#expect(review.ref.chat == "main")
		let card = try #require(review.cards.first)
		#expect(card.action == .add)
		#expect(card.name.sentence(in: displayLocale()) == "Endurance")
		#expect(card.date == "1998-06-14")
		#expect(
			card.lines(in: displayLocale()).joined(separator: "\n").hasPrefix(
				"Warmup\n- 10m 55-65%"))
		#expect(
			review.totals
				== ReviewTotals(additions: 1, edits: 0, deletions: 0, durationMinutes: nil))
		let live = try #require(
			try await ProposalPolicy.live(
				chatId: "main",
				ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
				now: clock.now))
		#expect(live.body.summary == "Create workout \"Endurance\" on 1998-06-14")
		#expect(live.body.expiresAt == clock.now.addingTimeInterval(10 * 60))
		#expect(
			!intervals.calls.contains { call in
				if case .createEvent = call { return true }
				return false
			}
		)
		#expect(await makeCoach().currentSnapshot(.main)?.review?.cards == review.cards)
	}

	@Test func calendarProposalSurvivesProviderErrorFinish() async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "intervals_create_workout", arguments: workoutArguments),
				.finish(reason: .toolCalls),
				.text("I've prepared the ride. Confirm to add it."),
				.finish(reason: .error),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		let review = try await proposeEnduranceRide(coach)
		#expect(
			review.cards.map { $0.name.sentence(in: displayLocale()) } == ["Endurance"])
		#expect(
			await coach.transcript(.main).contains("I've prepared the ride. Confirm to add it."))
	}

	var workoutArguments: String {
		#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}},{"type":"steady","duration":{"value":70,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}},{"type":"cooldown","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}}]}}"#
	}

	func proposeEnduranceRide(_ coach: Coach) async throws -> ReviewSnapshot {
		let turn = try #require(
			try await coach.send(draft("Give me an endurance ride for tomorrow"), to: .main)
				.acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		let snapshot = try #require(await coach.currentSnapshot(.main))
		return try #require(snapshot.review)
	}
}

extension FirstTurnTests {
	@Test func failedReviewRefreshKeepsTheCardUntilASuccessfulRead() async throws {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "intervals_create_workout", arguments: workoutArguments),
				.finish(reason: .toolCalls),
				.text("I've prepared the ride. Confirm to add it."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		let faults = FaultInjectingRecordLog(wrapping: store)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: faults, clock: clock)
		let proposed = try await proposeEnduranceRide(coach)
		#expect(await coach.decide(.presented(proposed.ref), in: .main) == .presentationRecorded)
		let ready = try #require(await coach.currentSnapshot(.main)?.review)
		let calls = intervals.calls
		let requests = transport.requestCount
		guard case .approveOrCancel = ready.controls else {
			Issue.record("presented review has no approval controls")
			return
		}
		faults.failFetches = true
		_ = await coach.decide(.presented(ready.ref), in: .main)
		let failed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(failed.ref == ready.ref)
		#expect(failed.cards == ready.cards)
		#expect(failed.controls == .none)
		#expect(failed.notice?.key == Catalog.reviewStorageUnavailable)
		#expect(
			coach.diagnostics.entries.contains {
				$0.event == .reviewUnavailable(.main, .unavailable)
			})
		for _ in 0..<2 {
			#expect(
				await coach.decide(.checkAgainWithoutToken(failed.ref), in: .main)
					== .storageUnavailable)
			#expect(await coach.currentSnapshot(.main)?.review == failed)
		}
		faults.failFetches = false
		#expect(
			await coach.decide(.checkAgainWithoutToken(failed.ref), in: .main)
				== .presentationRecorded)
		#expect(await coach.currentSnapshot(.main)?.review == ready)
		#expect(intervals.calls == calls)
		#expect(transport.requestCount == requests)
		guard case .approveOrCancel(let token) = ready.controls else { return }
		#expect(await coach.decide(.cancel(token), in: .main) == .canceled([]))
		#expect(await coach.currentSnapshot(.main)?.review == nil)
	}
}

extension ShortcutTurnTests {
	@Test func workoutToolCalledFromStatusWaitsForTheAthleteAndWritesNothing() async throws {
		let bench = ShortcutBench()
		let coach = try await bench.coach(replying: [
			.toolCall(
				name: "intervals_create_workout",
				arguments:
					#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
			), .finish(reason: .toolCalls),
			.text("Your Form is fresh. I drafted a ride for tomorrow."), .finish(reason: .stop),
		])

		let settled = try await coach.sendAndSettle("/status")

		#expect(replyText(settled) == "Your Form is fresh. I drafted a ride for tomorrow.")
		#expect(bench.transport.requests.count == 2)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(review.cards.map(\.action) == [.add])
		#expect(review.cards.map(\.date) == ["1998-06-14"])
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		guard case .approveOrCancel = await coach.currentSnapshot(.main)?.review?.controls else {
			Issue.record("the review is not waiting for the athlete's approval")
			return
		}
		#expect(try await bench.savedProposals() == 1)
		#expect(bench.intervals.calls.filter(\.isWrite).isEmpty)
		#expect(bench.intervals.events.isEmpty)
	}
}

extension ChoicesInConversationTests {
	@Test func numberAndLabelKeepWorkoutReviewPendingUntilExplicitApproval() async throws {
		let offer = offer
		transport.respond = ScriptedReply.sequence([
			.toolCall(
				name: "intervals_create_workout",
				arguments:
					#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":45,"unit":"minutes"}}]}}"#
			),
			.finish(reason: .toolCalls), .text(offer), .finish(reason: .stop),
			.text("We can build endurance without saving a plan or adding the ride."),
			.finish(reason: .stop),
			.text("Build speed is the direction; the ride still awaits its separate approval."),
			.finish(reason: .stop),
		])
		let coach = await makeCoach(transport: transport, intervals: intervals, store: records)
		let turn = try #require(
			try await coach.send(draft("Prepare a ride and offer planning directions."), to: .main)
				.acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == offer)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)

		for (answer, reply) in [
			("1", "We can build endurance without saving a plan or adding the ride."),
			(
				"I choose Build speed.",
				"Build speed is the direction; the ride still awaits its separate approval."
			),
		] {
			let selected = try #require(try await coach.send(draft(answer), to: .main).acceptedTurn)
			#expect(
				replyText(try #require(await coach.settledState(of: selected, in: .main))) == reply)
			#expect(await coach.currentSnapshot(.main)?.review?.token == token)
			#expect(intervals.calls.filter(\.isWrite).isEmpty)
			#expect(
				try await records.fetch(
					RecordQuery(scope: .deviceLocal([.planRevision, .planningCommand]))
				).records.isEmpty)
			#expect(
				try await records.fetch(RecordQuery(scope: .synced([.reviewWrite]))).records.isEmpty
			)
			let request = try #require(sent(.chatAttempt, by: transport).last)
			#expect(request.messages.contains { $0.role == .assistant && $0.content == offer })
			#expect(request.messages.last?.role == .user)
			#expect(request.messages.last?.content.hasPrefix(answer + "\nCurrent time:") == true)
		}
		let last = try #require(sent(.chatAttempt, by: transport).last)
		#expect(last.messages.contains { $0.role == .user && $0.unstampedContent == "1" })
		#expect(
			last.messages.contains {
				$0.role == .assistant
					&& $0.content
						== "We can build endurance without saving a plan or adding the ride."
			})

		#expect(
			await coach.decide(.approve(token), in: .main)
				== .completed([ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 1)))]))
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		let writes = try await records.fetch(RecordQuery(scope: .synced([.reviewWrite]))).records
		guard case .synced(.reviewWrite(let applied)) = writes.last?.body else {
			Issue.record("Expected durable calendar approval evidence.")
			return
		}
		#expect(
			intervals.calls.filter(\.isWrite) == [
				.createEvent(
					date: "1998-06-14", externalId: try #require(applied.writeID).externalID)
			])
		#expect(applied.evidence == .applied(eventID: 1))
		#expect(
			try await records.fetch(
				RecordQuery(scope: .deviceLocal([.planRevision, .planningCommand]))
			)
			.records.isEmpty)
	}
}

extension WorkoutAuthorizationTests {
	@Test(arguments: CalendarRequest.allCases)
	func schedulingAfterAProseWorkoutMakesOneReviewThatWaitsAndWritesNothing(
		request: CalendarRequest
	) async throws {
		let bench = AuthorizationBench()
		let coach = try await bench.coach(replying: [
			.text("Warm up, 2x15 minutes in Z4, cool down."), .finish(reason: .stop),
			.toolCall(name: request.tool.rawValue, arguments: request.arguments),
			.finish(reason: .toolCalls),
			.text("Ready for your approval."), .finish(reason: .stop),
		])
		_ = try await coach.sendAndSettle("Give me a threshold workout for 45 minutes indoors")
		try await bench.expectNoReviewAndAnUntouchedCalendar(coach)

		let settled = try await coach.sendAndSettle(request.message)

		#expect(replyText(settled) == "Ready for your approval.")
		#expect(bench.chatRequests.count == 3)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(review.cards.map(\.action) == [request.action])
		#expect(review.cards.map(\.date) == [request.date])
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		guard case .approveOrCancel = await coach.currentSnapshot(.main)?.review?.controls else {
			Issue.record("the review is not waiting for the athlete's approval")
			return
		}
		#expect(try await bench.savedProposals() == 1)
		#expect(bench.intervals.calls.filter(\.isWrite).isEmpty)
		#expect(bench.intervals.events == [AuthorizationBench.planned])
	}
}

extension ResetTests {
	@Test func resetLeavesWorkoutReviewUntouched() async throws {
		let nonce = Nonce()
		let proposal = sampleProposal(
			chatId: .main, nonce: nonce, expiresAt: clock.now.addingTimeInterval(300))
		try await seed(
			store,
			[
				seededRecord(
					store, at: clock.now.addingTimeInterval(-10),
					ulid: ULID.generate(at: clock.now.addingTimeInterval(-10)),
					body: .deviceLocal(.pendingProposal(proposal)))
			])
		let coach = await coach()
		answer("Here is Thursday.")
		_ = try await coach.sendAndSettle("Plan Thursday")
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		#expect(await coach.currentSnapshot(.main)?.review?.ref == review.ref)
		#expect(try await count(.deviceLocal([.proposalCleared])) == 0)
		#expect(await self.coach().currentSnapshot(.main)?.review?.ref.review == review.ref.review)
	}
}

extension TurnRunnerTests {
	@Test(arguments: [
		#"[{"type":"steady","duration":{"value":1.5e17,"unit":"minutes"}}]"#,
		#"[{"type":"steady","duration":{"value":86401,"unit":"seconds"}}]"#,
		#"[{"type":"steady","duration":{"value":1441,"unit":"minutes"}}]"#,
		#"[{"type":"steady","duration":{"value":1e20,"unit":"seconds"}}]"#,
		#"[{"type":"steady","duration":{"value":1e18,"unit":"minutes"}}]"#,
		#"[{"type":"steady","duration":{"value":1e308,"unit":"minutes"}}]"#,
		#"[{"type":"steady","duration":{"value":5e18,"unit":"seconds"}},{"type":"steady","duration":{"value":5e18,"unit":"seconds"}}]"#,
		#"[{"type":"set","repeat":20,"interval":{"type":"steady","duration":{"value":5e17,"unit":"seconds"}},"recovery":{"type":"rest","duration":{"value":30,"unit":"seconds"}}}]"#,
	])
	func oversizedWorkoutDurationsReturnErrors(steps: String) async throws {
		let result = try await toolResult(
			name: "intervals_create_workout",
			arguments:
				"{\"date\":\"1998-06-14\",\"workout\":{\"name\":\"Ride\",\"steps\":\(steps)}}")
		#expect(result.objectFields["error"] == .string("invalid_workout"))
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.isEmpty)
	}

	@Test(arguments: [
		#"{"value":86400,"unit":"seconds"}"#,
		#"{"value":1440,"unit":"minutes"}"#,
	])
	func workoutDurationLimitRemainsProposable(duration: String) async throws {
		let result = try await toolResult(
			name: "intervals_create_workout",
			arguments:
				#"{"date":"1998-06-14","workout":{"name":"Ride","steps":[{"type":"steady","duration":\#(duration)}]}}"#
		)
		#expect(result.objectFields["pendingConfirmation"] == .bool(true))
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal]))).records
				.count == 1)
	}
}
