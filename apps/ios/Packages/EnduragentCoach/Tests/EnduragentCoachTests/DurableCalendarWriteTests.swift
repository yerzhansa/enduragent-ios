import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct DurableCalendarWriteTests {
	enum LostResponse: Sendable, CaseIterable {
		case http500, http422, malformed, mismatched, timeout, cancellation

		var response: CalendarWriteServer.Response {
			switch self {
			case .http500: .status(500)
			case .http422: .status(422)
			case .malformed: .malformed
			case .mismatched:
				.body(
					#"{"id":99,"name":"Other","category":"WORKOUT","start_date_local":"1998-06-14T00:00:00"}"#
				)
			case .timeout, .cancellation: .heldAfterCommit
			}
		}
	}

	@Test(arguments: LostResponse.allCases)
	func committedWriteWithLostResponseIsConfirmedByReading(response: LostResponse) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = response.response }
		let fixture = await fixture(url: url, resourceTimeout: response == .timeout ? 1 : 30)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		let approving = Task { await fixture.coach.decide(.approve(token), in: .main) }
		try await waitUntil { server.posts.count == 1 && server.events.count == 1 }
		await fixture.coach.stop(.main)
		if response == .cancellation { approving.cancel() }
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approving.cancel()
					server.release()
				}
			) { await approving.value } != nil,
			"Calendar approval did not finish within five seconds")
		let state = try #require(await fixture.coach.state(of: turn))
		#expect((turnNotice(of: state)?.actions ?? []).isEmpty)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(pending.notice?.key.rawValue == "review.writePending")
		#expect(
			await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		let confirmed = try #require(await fixture.coach.state(of: turn))
		guard case .interrupted(let stopped) = confirmed else {
			Issue.record("expected stopped turn")
			return
		}
		#expect(stopped.saved.calendarWrites == 1)
		#expect(stopped.saved.unverifiedCalendarWrites == 0)
		#expect(stopped.notice.actions.isEmpty)
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await fixture.coach.retry(turn, in: .main)
		}
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
		#expect(server.posts.first?.target.contains("upsertOnUid=true") == true)
		#expect(server.posts.first?.body.objectFields["uid"]?.stringValue != nil)
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: fixture.store)
		#expect(await reopened.currentSnapshot(.main) == fixture.coach.currentSnapshot(.main))
	}

	@Test func emptyReadBeforeOriginalCommitsRepeatsOnlyTheApprovedUID() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .heldBeforeCommit }
		let fixture = await fixture(url: url)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		let approving = Task { await fixture.coach.decide(.approve(token), in: .main) }
		try await waitUntil { server.posts.count == 1 }
		approving.cancel()
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approving.cancel()
					server.release()
				}
			) { await approving.value } != nil,
			"Calendar approval did not finish within five seconds")
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
		let checked = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel(let retry) = checked.controls else {
			Issue.record("empty read must offer only repetition of the captured approval")
			return
		}
		#expect(
			(turnNotice(of: try #require(await fixture.coach.state(of: turn)))?.actions ?? [])
				.isEmpty
		)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await fixture.coach.retry(turn, in: .main)
		}
		server.state.withLock { $0.response = .success }
		#expect(
			await fixture.coach.decide(.retryRemaining(retry), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		server.release()
		#expect(server.posts.count == 2)
		#expect(server.posts.first?.body == server.posts.last?.body)
		#expect(server.events.count == 1)
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
	}

	@Test(arguments: [false, true])
	func unreadableCalendarKeepsTheWriteUnknown(malformed: Bool) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock {
			$0.response = .status(503)
			$0.readResponse = malformed ? .malformed : .disconnected
		}
		let fixture = await fixture(url: url)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		let review = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(review.ref), in: .main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(pending.notice?.key.rawValue == "review.writeReadFailed")
		#expect(
			(turnNotice(of: try #require(await fixture.coach.state(of: turn)))?.actions ?? [])
				.isEmpty
		)
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
	}

	@Test func storageFailureRetainsTheUnsentCard() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let store = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let fixture = await fixture(url: url, store: store)
		let (_, token) = try await proposal(on: fixture.coach, model: fixture.model)
		try store.failAppends(ofKind: "reviewWrite")
		#expect(await fixture.coach.decide(.approve(token), in: .main) == .storageUnavailable)
		#expect(await fixture.coach.currentSnapshot(.main)?.review?.token == token)
		#expect(server.posts.isEmpty)
		await fixture.coach.stop(.main)
	}

	func fixture(
		url: URL, resourceTimeout: TimeInterval = 30,
		store: any RecordLog = InMemoryRecordLog()
	) async -> CalendarFixture {
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForResource = resourceTimeout
		let client = IntervalsRESTClient(
			credential: .apiKey("test-calendar-key"),
			session: URLSession(configuration: configuration), clock: clock, baseURL: url)
		let model = FakeModelTransport()
		let coach = await makeCoach(transport: model, intervals: client, store: store, clock: clock)
		return CalendarFixture(coach: coach, model: model, client: client, store: store)
	}

	func proposal(on coach: Coach, model: FakeModelTransport, name: String = "Strength")
		async throws -> (TurnID, ReviewControlToken)
	{
		model.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments:
						"{\"date\":\"1998-06-14\",\"name\":\"\(name)\",\"description\":\"Three sets\"}"
				),
				.finish(reason: .toolCalls), .text("Review ready."), .hang,
			], for: .chat, otherwise: model.respond)
		let turn = try #require(
			try await coach.send(draft("Add a workout"), to: .main).acceptedTurn)
		let ready = try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
			snapshot in
			if case .processing? = snapshot.turns.first(where: { $0.id == turn })?.state {
				return snapshot.liveReply?.text.isEmpty == false
			}
			return false
		}
		if ready == nil { await coach.stop(.main) }
		try #require(ready != nil, "Calendar review did not become live within five seconds")
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		return (turn, try #require(await coach.currentSnapshot(.main)?.review?.token))
	}
}

struct CalendarFixture: Sendable {
	let coach: Coach
	let model: FakeModelTransport
	let client: IntervalsRESTClient
	let store: any RecordLog
}
