import EnduragentCoach
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [false, true], [LanguageTag.en, .fr])
	func failedChoiceSaveShowsOneLocalizedNoticeThroughShell(
		cancel: Bool, language: LanguageTag
	) async throws {
		let services = try services()
		let fixture = try #require(services.fixture)
		let model = await model(services)
		await model.agreeAndStartChatting()
		await model.chooseLanguage(.fixed(language))
		try await until { model.status.language == .fixed(language) }
		let token = try await presentedReview(on: model)
		_ = try await settledTurn(model)
		let ready = try #require(model.chat?.review)
		let requests = fixture.transport.requestCount
		fixture.records.failNextAppend = true
		await model.decide(cancel ? .cancel(token) : .approve(token))
		try await until { model.chat?.review == ready }
		let notice = try #require(model.reviewNotice)
		#expect(notice.key == CatalogKey(rawValue: "review.saveFailed"))
		#expect(
			notice.sentence(in: model.displayLocale)
				== (language == .en
					? "Couldn't save your choice on this iPhone, so nothing was changed. Try again."
					: "Impossible d’enregistrer votre choix sur cet iPhone. Rien n’a donc été modifié. Réessayez.")
		)
		#expect(model.chat?.review == ready)
		#expect(model.chat?.review?.notice == nil)
		#expect(model.chat?.notes.isEmpty == true)
		#expect(!fixture.intervals.calls.contains { $0.isCalendarWrite })
		#expect(fixture.transport.requestCount == requests)
	}

	@Test(arguments: [false, true], [LanguageTag.en, .fr])
	func failedChoiceReadShowsOneLocalizedCardNoticeThroughShell(
		cancel: Bool, language: LanguageTag
	) async throws {
		let services = try services()
		let fixture = try #require(services.fixture)
		let model = await model(services)
		await model.agreeAndStartChatting()
		await model.chooseLanguage(.fixed(language))
		try await until { model.status.language == .fixed(language) }
		let token = try await presentedReview(on: model)
		_ = try await settledTurn(model)
		let calls = fixture.intervals.calls
		let requests = fixture.transport.requestCount
		fixture.records.failFetches = true
		await model.decide(cancel ? .cancel(token) : .approve(token))
		try await until { model.chat?.review?.notice?.key == Catalog.reviewStorageUnavailable }
		let failed = try #require(model.chat?.review)
		let notice = try #require(failed.notice)
		#expect(model.reviewNotice == nil)
		#expect(model.chat?.notes.isEmpty == true)
		#expect(
			model.phrasebook.say(notice.key, notice.vars)
				== model.phrasebook.say(Catalog.reviewStorageUnavailable))
		let retry = try #require(ConfirmedPreviewCard(model: model, review: failed).actions.first)
		#expect(retry.id == "chat.preview.retryRead")
		await model.decide(retry.decision)
		#expect(model.chat?.review == failed)
		#expect(model.reviewNotice == nil)
		#expect(fixture.intervals.calls == calls)
		#expect(fixture.transport.requestCount == requests)
		fixture.records.failFetches = false
		await model.decide(retry.decision)
		try await until {
			guard case .approveOrCancel? = model.chat?.review?.controls else { return false }
			return true
		}
		#expect(model.reviewNotice == nil)
		#expect(model.chat?.review?.notice == nil)
		#expect(fixture.intervals.calls == calls)
		#expect(fixture.transport.requestCount == requests)
	}
}
