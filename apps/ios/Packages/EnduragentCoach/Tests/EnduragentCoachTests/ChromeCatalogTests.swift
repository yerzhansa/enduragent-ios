import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct ChromeCatalogTests {
	@Test(arguments: LanguageTag.allCases.filter { $0 != .en })
	func retainedNoticeAndControlsFollowALaterLanguageChoice(_ tag: LanguageTag) async throws {
		let transport = FakeModelTransport()
		transport.respond = { _ in ScriptedReply([.fail(.http(status: 400))]) }
		let store = InMemoryRecordLog()
		let coach = await makeCoach(transport: transport, store: store)
		try await coach.setLanguage(.fixed(.en))
		_ = try await coach.sendAndSettle("How was my training week?")
		let english = try await retainedCopy(of: coach)
		#expect(
			english == [
				"Sorry, something went wrong. Please try again.", "Try again", "Message your coach",
			])
		try await coach.setLanguage(.fixed(tag))
		var owner = coach
		for reopening in [false, true] {
			if reopening {
				await owner.lifecycle(.willTerminate)
				owner = await makeCoach(transport: transport, store: store)
			}
			let copy = try await retainedCopy(of: owner)
			try #require(copy.count == english.count)
			for (shown, source) in zip(copy, english) {
				#expect(shown != source)
				#expect(!shown.isEmpty)
				#expect(!shown.contains("%#@"))
			}
		}
		await owner.lifecycle(.willTerminate)
		#expect(transport.requestCount == 1)
	}

	private func retainedCopy(of coach: Coach) async throws -> [String] {
		let display = try await coach.observedStatus().displayLocale
		let state = try #require(await coach.currentSnapshot(.main)?.turns.last?.state)
		let notice = try #require(turnNotice(of: state))
		return [notice.sentence(in: display)]
			+ notice.actions.map { display.phrasebook.say($0.title) }
			+ [display.phrasebook.say(Catalog.chatComposerMessagePlaceholder)]
	}
}
