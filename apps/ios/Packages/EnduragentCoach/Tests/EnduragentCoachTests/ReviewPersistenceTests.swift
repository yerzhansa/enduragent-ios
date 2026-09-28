import Foundation
import Testing

@testable import EnduragentCoach

extension TurnRunnerTests {
	@Test func outcomeLineSurvivesRelaunch() async throws {
		transport.script = [
			.toolCall(
				name: "intervals_create_workout",
				arguments:
					#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
			),
			.finish(reason: .toolCalls),
			.text("I've prepared the ride. Confirm to add it."),
			.finish(reason: .stop),
		]
		let coach = makeCoach()
		_ = try await coach.sendAndSettle("Give me an endurance ride for tomorrow")
		let proposing = try #require(await coach.currentSnapshot(.main)?.turns.first?.id)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		let done = "Done — Create workout \"Endurance\" on 1998-06-14."
		let phrasebook = CatalogPhrasebook(tag: .en, locale: LanguageTag.en.defaultLocale)
		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(shown.notes.map { $0.notice.sentence(in: phrasebook) } == [done])
		#expect(shown.notes.first?.after == proposing)

		let reopened = makeCoach()
		let relaunched = try #require(await reopened.currentSnapshot(.main))
		#expect(relaunched.review == nil)
		#expect(relaunched.notes.map { $0.notice.sentence(in: phrasebook) } == [done])
		#expect(relaunched.notes.first?.after == proposing)
		let synced = try await store.fetch(
			RecordQuery(scope: .synced([.reviewApplied]), chatId: "main")
		).records
		#expect(synced.count == 1)

		transport.script = [.text("Saturday went well."), .finish(reason: .stop)]
		_ = try await reopened.sendAndSettle("How did Saturday go")
		let later = try #require(await reopened.currentSnapshot(.main))
		#expect(later.turns.count == 2)
		#expect(later.notes.first?.after == proposing)
	}

	func makeCoach(secrets: any SecretStore = keyedSecrets()) -> Coach {
		EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock, secrets: secrets
		)
	}
}
