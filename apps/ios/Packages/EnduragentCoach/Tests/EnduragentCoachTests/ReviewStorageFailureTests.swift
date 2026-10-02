import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SingleProposalReviewsTests {
	@Test(arguments: [false, true], [LanguageTag.en, .fr])
	func failedReviewChoiceSaveExplainsThatNothingChanged(cancel: Bool, language: LanguageTag)
		async throws
	{
		let faults = FaultInjectingRecordLog(wrapping: records)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: ada, store: faults, clock: clock, secrets: secrets)
		try await coach.setLanguage(.fixed(language))
		let token = try await presentedToken(on: coach)
		let ready = try #require(await coach.currentSnapshot(.main)?.review)
		let requests = transport.requestCount
		faults.failNextAppend = true
		let outcome = await coach.decide(cancel ? .cancel(token) : .approve(token), in: .main)
		#expect(outcome == .storageUnavailable)
		let notice = try #require(outcome.notice)
		#expect(notice.key == CatalogKey(rawValue: "review.saveFailed"))
		#expect(
			notice.sentence(in: displayLocale(language))
				== (language == .en
					? "Couldn't save your choice on this iPhone, so nothing was changed. Try again."
					: "Impossible d’enregistrer votre choix sur cet iPhone. Rien n’a donc été modifié. Réessayez.")
		)
		#expect(notice.action == nil)
		#expect(await coach.currentSnapshot(.main)?.review == ready)
		#expect(await coach.currentSnapshot(.main)?.notes.isEmpty == true)
		#expect(ada.calls.allSatisfy { !$0.isWrite })
		#expect(transport.requestCount == requests)
		#expect(
			try await records.fetch(RecordQuery(scope: .synced([.reviewWrite]), chatId: .main))
				.records.isEmpty)
		#expect(
			try await records.fetch(
				RecordQuery(scope: .deviceLocal([.proposalCleared]), chatId: .main)
			).records.isEmpty)
		await coach.lifecycle(.willTerminate)
	}

	enum UnreadReviewAction: CaseIterable, Sendable { case add, cancel, retry }

	@Test(arguments: UnreadReviewAction.allCases, [LanguageTag.en, .fr])
	func failedReviewActionReadShowsOnlyTheLocalizedCardNotice(
		action: UnreadReviewAction, language: LanguageTag
	) async throws {
		let faults = FaultInjectingRecordLog(wrapping: records)
		let coach = await EnduragentCoachTests.makeCoach(
			transport: transport, intervals: ada, store: faults, clock: clock, secrets: secrets)
		try await coach.setLanguage(.fixed(language))
		let token = try await presentedToken(on: coach)
		let ready = try #require(await coach.currentSnapshot(.main)?.review)
		let calls = ada.calls
		let requests = transport.requestCount
		faults.failFetches = true
		if action == .retry { _ = await coach.decide(.presented(token.ref), in: .main) }
		let decision: ReviewDecision =
			switch action {
			case .add: .approve(token)
			case .cancel: .cancel(token)
			case .retry: .checkAgain(token.ref)
			}
		#expect(await coach.decide(decision, in: .main) == .storageUnavailable)
		let snapshot = try #require(await coach.currentSnapshot(.main))
		let failed = try #require(snapshot.review)
		#expect(failed.ref == ready.ref)
		#expect(failed.cards == ready.cards)
		#expect(failed.controls == .none)
		let notice = try #require(failed.notice)
		#expect(notice.key == Catalog.reviewStorageUnavailable)
		let lines =
			[language.phrasebook.say(notice.key, notice.vars)]
			+ snapshot.notes.values.flatMap { $0 }.map { $0.sentence(in: displayLocale(language)) }
		#expect(lines == [language.phrasebook.say(Catalog.reviewStorageUnavailable)])
		#expect(!lines.contains(language.phrasebook.say(Catalog.coachErrorUnknown)))
		#expect(ada.calls == calls)
		#expect(transport.requestCount == requests)
		faults.failFetches = false
		await coach.lifecycle(.willTerminate)
	}
}
