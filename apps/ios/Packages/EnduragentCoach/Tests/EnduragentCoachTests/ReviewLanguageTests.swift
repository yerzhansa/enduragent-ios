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

	@Test func reviewInstructionsFollowTheChosenLanguageWithoutChangingTheCalendarFormat()
		async throws
	{
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_workout",
					arguments:
						#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}},{"type":"ramp","duration":{"value":20,"unit":"minutes"},"power":{"kind":"percent_ftp","low":60,"high":80},"label":"Warmup ramp"},{"type":"cooldown","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","value":50}}]}}"#
				),
				.finish(reason: .toolCalls), .text("Ready."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		let review = try await proposeEnduranceRide(coach)
		let card = try #require(review.cards.first)
		try await coach.setLanguage(.fixed(.fr))
		let french = try await coach.observedStatus().displayLocale
		#expect(
			card.lines(in: french) == [
				"Échauffement", "- 10m 50%", "", "Bloc principal",
				"- 20m progressif 60-80% Warmup ramp", "", "Retour au calme", "- 10m 50%",
			])
		#expect(
			card.lines(in: displayLocale()) == [
				"Warmup", "- 10m 50%", "", "Main set", "- 20m ramp 60-80% Warmup ramp",
				"", "Cooldown", "- 10m 50%",
			])
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([
					ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))
				]))
	}
}
