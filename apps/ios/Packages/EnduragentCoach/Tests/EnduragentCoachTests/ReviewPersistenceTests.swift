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
		let coach = await makeCoach()
		_ = try await coach.sendAndSettle("Give me an endurance ride for tomorrow")
		let proposing = try #require(await coach.currentSnapshot(.main)?.turns.first?.id)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		let done = "Done — Create workout \"Endurance\" on 1998-06-14."
		let phrasebook = CatalogPhrasebook(tag: .en)
		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(shown.notes.map { $0.sentence(in: phrasebook) } == [done])
		#expect(shown.notes.first?.after == proposing)

		try await coach.setLanguage(.fixed(.fr))
		let french = try await coach.observedStatus().language.phrasebook(device: .en)
		let frenchDone = "C’est fait — Créer l’entraînement « Endurance » le 1998-06-14."
		#expect(shown.notes.map { $0.sentence(in: french) } == [frenchDone])

		let reopened = await makeCoach()
		let relaunched = try #require(await reopened.currentSnapshot(.main))
		#expect(relaunched.review == nil)
		#expect(relaunched.notes.map { $0.sentence(in: phrasebook) } == [done])
		#expect(relaunched.notes.first?.after == proposing)
		#expect(relaunched.notes.map { $0.sentence(in: french) } == [frenchDone])
		let synced = try await store.fetch(
			RecordQuery(scope: .synced([.reviewApplied]), chatId: "main")
		).records
		#expect(synced.count == 1)

		transport.script = [.text("Saturday went well."), .finish(reason: .stop)]
		_ = try await reopened.sendAndSettle("How did Saturday go")
		let later = try #require(await reopened.currentSnapshot(.main))
		#expect(later.turns.count == 2)
		#expect(later.notes.first?.after == proposing)
		#expect(await reopened.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(await reopened.currentSnapshot(.main)?.notes.isEmpty == true)
		let archivedRef = try #require(try await reopened.history().first?.id)
		let archived = try #require(try await reopened.archivedConversation(archivedRef))
		#expect(archived.notes.map { $0.sentence(in: french) } == [frenchDone])
		#expect(archived.notes.first?.after == proposing)
		let archivedAfterRelaunchRef = try #require(try await makeCoach().history().first?.id)
		let archivedAfterRelaunch = try #require(
			try await makeCoach().archivedConversation(archivedAfterRelaunchRef))
		#expect(archivedAfterRelaunch.notes.map { $0.sentence(in: french) } == [frenchDone])
	}

	func makeCoach(secrets: any SecretStore = keyedSecrets()) async -> Coach {
		await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock, secrets: secrets
		)
	}
}

extension SingleProposalReviewsTests {
	@Test func approvalAfterNewConversationIsKeptInHistory() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(shown.turns.isEmpty)
		#expect(shown.notes.count == 1)
		#expect(await coach.startNewConversation(in: .main) == .started(memory: .saved))
		let history = try await coach.history()
		#expect(history.count == 2)
		let ref = try #require(history.first?.id)
		#expect(history.first?.firstQuestion == nil)
		let archived = try #require(try await coach.archivedConversation(ref))
		#expect(archived.turns.isEmpty)
		#expect(archived.notes == shown.notes)
		#expect(try await self.coach().archivedConversation(ref)?.notes == shown.notes)
	}
}
