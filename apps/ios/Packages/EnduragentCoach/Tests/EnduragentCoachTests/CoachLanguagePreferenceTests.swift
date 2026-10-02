import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct CoachLanguagePreferenceTests {
	@Test(arguments: [
		(
			LanguagePreference.automatic, LanguagePreference.fixed(.de), LanguageTag.nl,
			"Stuur je coach een bericht"
		),
		(.fixed(.fr), .automatic, .fr, "Écris à ton coach"),
		(.fixed(.fr), .fixed(.de), .fr, "Écris à ton coach"),
	])
	func failedLanguageWritesKeepThePreviousLanguageThroughRelaunch(
		current: LanguagePreference, attempted: LanguagePreference, expected: LanguageTag,
		placeholder: String
	) async throws {
		let transport = FakeModelTransport()
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let coach = await makeCoach(transport: transport, store: log, deviceLanguage: .nl)
		try await coach.setLanguage(current)
		try log.failAppends(ofKind: "languagePreference")
		await #expect(throws: PreferenceWriteFailure.notSaved) {
			try await coach.setLanguage(attempted)
		}
		let reopened = await makeCoach(transport: transport, store: log, deviceLanguage: .nl)
		for owner in [coach, reopened] {
			let status = try await owner.observedStatus()
			#expect(status.language == current)
			#expect(
				status.language.phrasebook(device: .nl).say(Catalog.chatComposerMessagePlaceholder)
					== placeholder)
			transport.respond = ScriptedReply.sequence(
				[.text("Reply"), .finish(reason: .stop)], otherwise: transport.respond)
			_ = try await owner.sendAndSettle("How was my training week?")
			let system = try #require(
				sent(.chatAttempt, by: transport).last?.messages.first?.content)
			#expect(
				system.contains(
					"Write every athlete-facing sentence in \(expected.englishName), even when the athlete writes in another language."
				))
		}
	}

	@Test func savedLanguageLoadsWhileTrainingDisplayIsBlocked() async throws {
		let store = InMemoryRecordLog()
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let first = await makeCoach(
			transport: FakeModelTransport(), intervals: intervals, store: store)
		try await first.setLanguage(.fixed(.es))
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: intervals, store: store)
		#expect(await reopened.languagePreference() == .fixed(.es))
		#expect(intervals.calls.isEmpty)
		let gate = intervals.holdNextProfileRead()
		defer { Task { await gate.release() } }
		#expect(try await reopened.observedStatus().language == .fixed(.es))
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					Task { await gate.release() }
				}
			) { await gate.waitUntilEntered() } != nil)
		#expect(intervals.calls.isEmpty)
		await gate.release()
		await reopened.lifecycle(.becameActive)
		#expect(!intervals.calls.isEmpty)
	}
}
