import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension FirstTurnTests {
	@Test func malformedStoredWorkoutIsRejectedBeforeReviewRendering() throws {
		let workout = IntervalsWorkoutInput(
			name: "Broken",
			steps: [
				.simple(
					SimpleStep(
						type: .ramp, duration: DurationInput(value: 10, unit: .minutes),
						power: PowerTarget(kind: .zone, value: nil, low: 1, high: 99), cadence: nil,
						label: nil))
			])
		let body = RecordBody.deviceLocal(
			.pendingProposal(
				ProposalBody(
					chatId: .main, nonce: Nonce(),
					tool: .intervalsCreateWorkout,
					toolInput: .createWorkout(date: "1998-06-14", workout: workout),
					summary: "Broken", description: "Broken", expiresAt: clock.now)))
		let encoded = try RecordCodec.encode(body)
		let decoded = RecordCodec.decode(
			kind: "pendingProposal", version: encoded.version,
			data: encoded.data, civilDate: "1998-06-13", ulid: "fixture")
		guard case .failure(.malformed) = decoded else {
			Issue.record("Invalid stored workout was accepted for review")
			return
		}
	}

	@Test(arguments: [("en_US", ".", "6/14/1998"), ("fr_FR", ",", "14/06/1998")])
	func reviewInstructionsFollowTheChosenLanguageWithoutChangingTheCalendarFormat(
		region: String, decimal: String, date: String
	) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let client = IntervalsRESTClient(
			credential: .apiKey("test-calendar-key"),
			session: URLSession(configuration: .ephemeral), clock: clock, baseURL: url)
		let secrets = keyedSecrets()
		let resolver: DisplayLocaleResolver = {
			DisplayLocale(
				preference: $0, preferredLanguages: ["en"],
				regionalConventions: Locale(identifier: region))
		}
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_workout",
					arguments:
						#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"warmup","duration":{"value":10.5,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50.5}},{"type":"ramp","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":60.5,"high":80.5},"cadence":{"value":90},"label":"Warmup ramp 1.5"},{"type":"set","repeat":2,"interval":{"type":"interval","duration":{"value":10,"unit":"minutes"},"power":{"kind":"watts","low":190.5,"high":225.5},"cadence":{"low":85,"high":95}},"recovery":{"type":"recovery","duration":{"value":5,"unit":"minutes"},"power":{"kind":"zone","low":1,"high":2}}},{"type":"cooldown","duration":{"value":10,"unit":"minutes"},"power":{"kind":"watts","value":100.5}}]}}"#
				),
				.finish(reason: .toolCalls), .text("Ready."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: client, store: store, clock: clock,
			secrets: secrets, displayLocale: resolver)
		let review = try await proposeEnduranceRide(coach)
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let pending = try #require(
			try await ProposalPolicy.live(chatId: .main, ledger: ledger, now: clock.now))
		let writeID = try #require(pending.body.writeID)
		let calls = transport.requests.count
		try await coach.setLanguage(.fixed(.fr))
		let reopened = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: client, store: store, clock: clock,
			secrets: secrets, displayLocale: resolver)
		let observed = try #require(
			try await firstSnapshot(in: await reopened.observe(.main), within: .hangGuard) {
				$0.review != nil
			})
		let restored = try #require(observed.review)
		#expect(restored.ref.set == review.ref.set)
		#expect(restored.ref.revision == review.ref.revision)
		#expect(await reopened.decide(.showAgain(restored.ref), in: .main) == .presentationRecorded)
		let shown = try #require(await reopened.currentSnapshot(.main)?.review)
		let card = try #require(shown.cards.first)
		let french = try await reopened.observedStatus().displayLocale
		#expect(card.action == .add)
		#expect(card.date == "1998-06-14")
		#expect(card.name.sentence(in: french) == "Endurance")
		#expect(ReviewSummary(pending.body.toolInput).sentence(in: french).contains(date))
		#expect(
			card.lines(in: french) == [
				"Échauffement", "- 10m30 50\(decimal)5%", "", "Bloc principal",
				"- 10m progressif 60\(decimal)5-80\(decimal)5% 90rpm Warmup ramp 1.5", "2x",
				"- 10m 190\(decimal)5-225\(decimal)5w 85-95rpm", "- 5m Z1-Z2", "",
				"Retour au calme", "- 10m 100\(decimal)5w",
			])
		#expect(!card.lines(in: french).joined().contains("{\""))
		#expect(server.writes.isEmpty)
		#expect(transport.requests.count == calls)
		#expect(await reopened.decide(.presented(shown.ref), in: .main) == .presentationRecorded)
		let token = try #require(await reopened.currentSnapshot(.main)?.review?.token)
		#expect(
			await reopened.decide(.approve(token), in: .main)
				== .applied([
					ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))
				]))
		try #require(server.writes.count == 1)
		let request = try #require(server.posts.first)
		#expect(request.method == "POST")
		#expect(request.target == "/athlete/0/events?upsertOnUid=true")
		let fields = request.body.objectFields
		#expect(fields["start_date_local"] == .string("1998-06-14T00:00:00"))
		#expect(fields["name"] == .string("Endurance"))
		#expect(fields["type"] == .string("Ride"))
		#expect(fields["category"] == .string("WORKOUT"))
		#expect(fields["tags"] == .array([.string("cycling-coach")]))
		#expect(fields["uid"] == .string(writeID.uid))
		#expect(fields["external_id"] == .string(writeID.externalID))
		#expect(
			fields["description"]
				== .string(
					[
						"Warmup", "- 10m30 50.5%", "", "Main set",
						"- 10m ramp 60.5-80.5% 90rpm Warmup ramp 1.5", "2x",
						"- 10m 190.5-225.5w 85-95rpm", "- 5m Z1-Z2", "", "Cooldown", "- 10m 100.5w",
					].joined(separator: "\n")))
		#expect(transport.requests.count == calls)
	}
}
