import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension TurnRunnerTests {
	@Test func outcomeLineSurvivesRelaunch() async throws {
		let phone = DisplayPhone()
		phone.change(languages: ["en"], region: "en_US")
		transport.respond = ScriptedReply.sequence(
			workoutProposal + [
				.text("I've prepared the ride. Confirm to add it."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach(displayLocale: phone.resolve)
		_ = try await coach.sendAndSettle("Give me an endurance ride for tomorrow")
		let proposing = try #require(await coach.currentSnapshot(.main)?.turns.first?.id)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		let done = "Done — Create workout \"Endurance\" on 6/14/1998."
		let phrasebook = displayLocale()
		let shown = try #require(await coach.currentSnapshot(.main))
		#expect((shown.notes[proposing] ?? []).map { $0.sentence(in: phrasebook) } == [done])
		#expect(shown.notes[proposing]?.first?.after == proposing)

		try await coach.setLanguage(.fixed(.fr))
		let french = try await coach.observedStatus().displayLocale
		let frenchDone = "C’est fait — Créer l’entraînement « Endurance » le 6/14/1998."
		#expect((shown.notes[proposing] ?? []).map { $0.sentence(in: french) } == [frenchDone])

		let reopened = await makeCoach(displayLocale: phone.resolve)
		#expect(try await reopened.observedStatus().displayLocale == french)
		let relaunched = try #require(await reopened.currentSnapshot(.main))
		#expect(relaunched.review == nil)
		#expect((relaunched.notes[proposing] ?? []).map { $0.sentence(in: phrasebook) } == [done])
		#expect(relaunched.notes[proposing]?.first?.after == proposing)
		#expect((relaunched.notes[proposing] ?? []).map { $0.sentence(in: french) } == [frenchDone])
		let calls = transport.requests.count
		try await reopened.setLanguage(.fixed(.en))
		phone.change(languages: ["fr"], region: "fr_FR")
		await reopened.refreshDisplayLocale()
		let regional = try await reopened.observedStatus().displayLocale
		let regionalDone = "Done — Create workout \"Endurance\" on 14/06/1998."
		#expect(
			(relaunched.notes[proposing] ?? []).map { $0.sentence(in: regional) } == [regionalDone])
		#expect(transport.requests.count == calls)
		let synced = try await store.fetch(
			RecordQuery(scope: .synced([.reviewApplied]), chatId: "main")
		).records
		#expect(synced.count == 1)

		transport.respond = ScriptedReply.sequence(

			[.text("Saturday went well."), .finish(reason: .stop)], for: .chat,
			otherwise: transport.respond)
		_ = try await reopened.sendAndSettle("How did Saturday go")
		let later = try #require(await reopened.currentSnapshot(.main))
		#expect(later.turns.count == 2)
		#expect(later.notes[proposing]?.first?.after == proposing)
		#expect(await reopened.resetAndSettle(in: .main) == .started(memory: .saved))
		#expect(await reopened.currentSnapshot(.main)?.notes.isEmpty == true)
		let archivedRef = try #require(try await reopened.history().first?.id)
		let archived = try #require(try await reopened.archivedConversation(archivedRef))
		#expect(archived.notes.map { $0.sentence(in: regional) } == [regionalDone])
		#expect(archived.notes.first?.after == proposing)
		try await reopened.setLanguage(.fixed(.fr))
		let laterFrench = try await reopened.observedStatus().displayLocale
		let laterFrenchDone = "C’est fait — Créer l’entraînement « Endurance » le 14/06/1998."
		#expect(archived.notes.map { $0.sentence(in: laterFrench) } == [laterFrenchDone])
		let historyCoach = await makeCoach(displayLocale: phone.resolve)
		#expect(try await historyCoach.observedStatus().displayLocale == laterFrench)
		let archivedAfterRelaunchRef = try #require(try await historyCoach.history().first?.id)
		let archivedAfterRelaunch = try #require(
			try await historyCoach.archivedConversation(archivedAfterRelaunchRef))
		#expect(
			archivedAfterRelaunch.notes.map { $0.sentence(in: laterFrench) } == [laterFrenchDone])
	}

	@Test func legacySuppliedOutcomeAndInstructionsStayUnchanged() async throws {
		let legacy = "Create workout Legacy on 1998-06-14 at 1.5w"
		let decoded = try RecordCodec.decode(
			kind: "reviewApplied", version: 2,
			data: Data(
				#"{"chatId":"main","summary":"Create workout Legacy on 1998-06-14 at 1.5w"}"#.utf8),
			civilDate: "1998-06-13", ulid: fixedUlid(1).rawValue
		).get()
		try await seed(
			store, [seededRecord(store, at: clock.now, ulid: fixedUlid(1), body: decoded)])
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments:
						#"{"date":"1998-06-14","name":"Copied Core","description":"10.5 minutes\nCopied label 1.5"}"#
				),
				.finish(reason: .toolCalls), .text("Ready."), .finish(reason: .stop),
			], otherwise: transport.respond)
		let coach = await makeCoach()
		_ = try await coach.sendAndSettle("Add a core workout tomorrow")
		let calls = transport.requests.count
		try await coach.setLanguage(.fixed(.fr))
		let reopened = await makeCoach()
		let display = try await reopened.observedStatus().displayLocale
		let snapshot = try #require(await reopened.currentSnapshot(.main))
		let card = try #require(snapshot.review?.cards.first)
		#expect(card.name.sentence(in: display) == "Copied Core")
		#expect(card.lines(in: display) == ["10.5 minutes", "Copied label 1.5"])
		#expect(
			snapshot.notes.values.flatMap { $0 }.map { $0.sentence(in: display) } == [
				"C’est fait — " + legacy + "."
			])
		#expect(transport.requests.count == calls)
		#expect(intervals.calls.allSatisfy { !$0.isWrite })
	}

	func makeCoach(
		secrets: any SecretStore = keyedSecrets(),
		displayLocale: @escaping DisplayLocaleResolver = testDisplayLocale
	) async -> Coach {
		await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock,
			secrets: secrets,
			displayLocale: displayLocale
		)
	}
}

extension SingleProposalReviewsTests {
	@Test func approvalAfterNewConversationIsKeptInHistory() async throws {
		let coach = await coach()
		let token = try await presentedToken(on: coach)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		let shown = try #require(await coach.currentSnapshot(.main))
		#expect(shown.turns.isEmpty)
		#expect(shown.notes[nil]?.count == 1)
		#expect(await coach.resetAndSettle(in: .main) == .started(memory: .saved))
		let history = try await coach.history()
		#expect(history.count == 2)
		let ref = try #require(history.first?.id)
		#expect(history.first?.firstQuestion == nil)
		let archived = try #require(try await coach.archivedConversation(ref))
		#expect(archived.turns.isEmpty)
		#expect(archived.notes == shown.notes[nil])
		#expect(try await self.coach().archivedConversation(ref)?.notes == shown.notes[nil])
	}
}
