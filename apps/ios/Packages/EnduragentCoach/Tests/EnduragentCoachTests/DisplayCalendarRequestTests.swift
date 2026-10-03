import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct DisplayCalendarRequestTests {
	@Test func redisplayAndApprovalKeepActualCalendarBytesAndCopiedText() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .heldBeforeCommit }
		let clock = FixedClock(now: "2026-03-04T13:05:00Z", timeZone: "UTC")
		let client = IntervalsRESTClient(
			credential: .apiKey("test-calendar-key"),
			session: URLSession(configuration: .ephemeral),
			clock: clock, baseURL: url)
		let phone = DisplayPhone()
		let transport = FakeModelTransport()
		let arguments =
			#"{"date":"2026-03-05","workout":{"name":"Copied ride 1.5","steps":[{"type":"steady","duration":{"value":12.5,"unit":"minutes"},"power":{"kind":"percent_ftp","low":60.5,"high":75.5},"label":"Athlete label 1.5"}]}}"#
		let reply = "Cited title: Tuesday sweet spot. Copied activity: Saturday group ride."
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: "intervals_create_workout", arguments: arguments),
				.finish(reason: .toolCalls), .text(reply), .hang,
			],
			for: .chat, otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: client, store: InMemoryRecordLog(), clock: clock,
			displayLocale: phone.resolve)
		let athleteText = "Keep my words 1.5 and 2026-03-05 unchanged."
		_ = try #require(try await coach.send(draft(athleteText), to: .main).acceptedTurn)
		let ready = try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
				$0.liveReply?.text == reply && $0.review != nil
			})
		let review = try #require(ready.review)
		_ = await coach.decide(.presented(review.ref), in: .main)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let approving = Task { await coach.decide(.approve(token), in: .main) }
		try await waitUntil { server.posts.count == 1 }
		approving.cancel()
		try #require(
			try await beforeDeadline(within: .hangGuard, onTimeout: { server.release() }) {
				await approving.value
			} != nil)
		await coach.stop(.main)
		let before = try #require(server.posts.first)
		let calls = sent(.chatAttempt, by: transport).count
		try await coach.setLanguage(.fixed(.fr))
		phone.change(languages: ["en"], region: "fr_FR")
		await coach.refreshDisplayLocale()
		let display = try await coach.observedStatus().displayLocale
		let reopened = try #require(await coach.currentSnapshot(.main))
		#expect(reopened.turns.first?.athleteText == athleteText)
		guard case .interrupted(let stopped)? = reopened.turns.first?.state else {
			Issue.record("The stopped reply was not retained")
			return
		}
		#expect(stopped.partial == reply)
		let card = try #require(reopened.review?.cards.first)
		#expect(card.name.sentence(in: display) == "Copied ride 1.5")
		#expect(card.lines(in: display).joined(separator: "\n").contains("Athlete label 1.5"))
		let pending = try #require(reopened.review)
		_ = await coach.decide(.checkAgain(pending.ref), in: .main)
		let checked = try #require(await coach.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel(let repeatWrite) = checked.controls else {
			Issue.record("An uncommitted write did not offer its approved operation")
			return
		}
		server.state.withLock { $0.response = .success }
		#expect(
			await coach.decide(.retryRemaining(repeatWrite), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		let after = try #require(server.posts.last)
		try #require(server.posts.count == 2)
		#expect(before.method == "POST")
		#expect(before.target.contains("upsertOnUid=true"))
		#expect(before.method == after.method)
		#expect(before.target == after.target)
		#expect(before.bodyBytes == after.bodyBytes)
		#expect(after.body.objectFields["name"]?.stringValue == "Copied ride 1.5")
		#expect(after.body.objectFields["start_date_local"]?.stringValue == "2026-03-05T00:00:00")
		#expect(
			after.body.objectFields["description"]?.stringValue?.contains(
				"60.5-75.5% Athlete label 1.5") == true)
		#expect(sent(.chatAttempt, by: transport).count == calls)
		let systems = sent(.chatAttempt, by: transport).flatMap(\.messages)
		let toolArguments = systems.flatMap { $0.toolCalls }.map(\.arguments)
		#expect(toolArguments.contains(arguments))
		let legacy = ReviewSummary.supplied("Legacy 2026-03-05, 1.5, copied title")
		#expect(legacy.sentence(in: display) == "Legacy 2026-03-05, 1.5, copied title")
		server.release()
	}
}
