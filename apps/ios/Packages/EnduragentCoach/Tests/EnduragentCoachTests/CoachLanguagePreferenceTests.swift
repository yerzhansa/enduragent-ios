import Testing

@testable import EnduragentCoach

@Suite struct CoachLanguagePreferenceTests {
	@Test(arguments: [LanguagePreference.automatic, .fixed(.it)])
	func mirrorFollowsTheAthleteMessageWhileFixedKeepsItsLanguage(
		preference: LanguagePreference
	) async throws {
		let transport = FakeModelTransport()
		let coach = makeCoach(
			transport: transport, store: InMemoryRecordLog(), deviceLanguage: .nl)
		try await coach.setLanguage(preference)
		for (message, detected) in [
			("Comment était ma semaine et que dois-je faire aujourd'hui ?", LanguageTag.fr),
			("How was my training week and what should I do today?", .en),
			("123", .nl),
		] {
			transport.script = [.text("Reply"), .finish(reason: .stop)]
			_ = try await coach.sendAndSettle(message)
			let system = try #require(
				sent(.chatAttempt, by: transport).last?.messages.first?.content)
			switch preference {
			case .automatic:
				#expect(system.contains("Reply in the language of the athlete's latest message"))
				#expect(system.contains("reply in \(detected.englishName) (\(detected.endonym))."))
			case .fixed:
				#expect(system.contains("The athlete chose Italian (Italiano)."))
				#expect(system.contains("never mirror the language itself."))
			}
		}
	}

	@Test func savedLanguageLoadsWithoutReadingTraining() async throws {
		let store = InMemoryRecordLog()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let first = makeCoach(transport: FakeModelTransport(), intervals: intervals, store: store)
		try await first.setLanguage(.fixed(.es))
		let reopened = makeCoach(
			transport: FakeModelTransport(), intervals: intervals, store: store)
		#expect(await reopened.languagePreference() == .fixed(.es))
		#expect(intervals.calls.isEmpty)
		#expect(await reopened.status().language == .fixed(.es))
		#expect(!intervals.calls.isEmpty)
	}
}
