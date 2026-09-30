import Testing

@testable import EnduragentCoach

@Suite struct CoachLanguagePreferenceTests {
	@Test func savedLanguageLoadsWithoutReadingTraining() async throws {
		let store = InMemoryRecordLog()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let first = await makeCoach(
			transport: FakeModelTransport(), intervals: intervals, store: store)
		try await first.setLanguage(.fixed(.es))
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: intervals, store: store)
		#expect(await reopened.languagePreference() == .fixed(.es))
		#expect(intervals.calls.isEmpty)
		#expect(await reopened.status().language == .fixed(.es))
		#expect(!intervals.calls.isEmpty)
	}
}
