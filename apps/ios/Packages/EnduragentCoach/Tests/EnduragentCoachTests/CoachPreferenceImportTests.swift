import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

@Suite struct CoachPreferenceImportTests {
	@Test(arguments: [false, true])
	func importedLanguagePublishesAndAutomaticOverrideSurvivesReopening(openConversation: Bool)
		async throws
	{
		let store = ImportingRecordLog()
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		let snapshots = await coach.observeStatus()
		var initial = snapshots.makeAsyncIterator()
		#expect(await initial.next()?.language == .automatic)
		if openConversation { _ = await coach.currentSnapshot(.main) }
		let remote = await remoteCoach(sharing: store)
		try await remote.setLanguage(.fixed(.es))
		store.notifyImport()
		#expect(await snapshots.status { $0.language == .fixed(.es) }?.language == .fixed(.es))
		#expect(await coach.languagePreference() == .fixed(.es))
		try await coach.setLanguage(.automatic)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: store)
		#expect(await reopened.languagePreference() == .automatic)
		let written = try await store.fetch(RecordQuery(scope: .synced([.languagePreference])))
		#expect(written.records.count == 2)
		#expect(written.records.last?.deviceId == store.deviceId)
		#expect(store.subscriptions == 1)
	}

	@Test func importReadKeepsLocalPreferencesCommittedWhileItWaits() async throws {
		let store = ImportingRecordLog()
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: store,
			clock: FixedClock(now: "2034-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"))
		let snapshots = await coach.observeStatus()
		var published = snapshots.makeAsyncIterator()
		#expect(await published.next()?.language == .automatic)
		let remote = await remoteCoach(sharing: store)
		let imported = try SessionSettings.npmDefaults.replacing(
			.contextWindowOverride, with: "64000")
		try await remote.setLanguage(.fixed(.es))
		try await remote.setSession(imported)
		let read = store.holdRead(scope: Preferences.scope)
		defer { read.release() }
		store.notifyImport()
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await read.waitUntilParked()
			} != nil,
			"Preference import read did not park")
		try await coach.setLanguage(.fixed(.fr))
		#expect(await published.next()?.language == .fixed(.fr))
		let local = try SessionSettings.npmDefaults.replacing(
			.contextWindowOverride, with: "96000")
		try await coach.setSession(local)
		#expect(await published.next()?.session == local)
		read.release()
		let refreshed = await snapshots.status { $0.language == .fixed(.fr) && $0.session == local }
		#expect(refreshed?.language == .fixed(.fr))
		#expect(refreshed?.session == local)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: store)
		#expect(try await reopened.observedStatus().language == .fixed(.fr))
		#expect(try await reopened.observedStatus().session == local)
	}

	@Test func failedImportKeepsPreferencesAndRetriesTheNextNotification() async throws {
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let store = ImportingRecordLog(inner: faults)
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		try await coach.setLanguage(.fixed(.fr))
		let snapshots = await coach.observeStatus()
		var initial = snapshots.makeAsyncIterator()
		#expect(await initial.next()?.language == .fixed(.fr))
		let remote = await remoteCoach(sharing: store)
		let session = try SessionSettings.npmDefaults.replacing(
			.contextWindowOverride, with: "64000")
		try await remote.setLanguage(.fixed(.es))
		try await remote.setSession(session)
		faults.failFetches = true
		store.notifyImport()
		try await waitUntil {
			coach.diagnostics.entries.contains { $0.event == .preferencesUnavailable(.unavailable) }
		}
		#expect(await coach.languagePreference() == .fixed(.fr))
		faults.failFetches = false
		store.notifyImport()
		let refreshed = await snapshots.status {
			$0.language == .fixed(.es) && $0.session == session
		}
		#expect(refreshed?.language == .fixed(.es))
		#expect(refreshed?.session == session)
		#expect(store.subscriptions == 1)
	}

	@Test func importDuringTheInitialPreferenceReadReachesTheStatusObserver() async throws {
		let records = BatchRecordingLog(inner: InMemoryRecordLog())
		let store = ImportingRecordLog(inner: records)
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		let read = store.holdRead(scope: Preferences.scope)
		defer { read.release() }
		let observing = Task { await coach.observeStatus() }
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await read.waitUntilParked()
			} != nil,
			"Initial preference read did not park")
		let remote = await remoteCoach(sharing: store)
		try await remote.setLanguage(.fixed(.es))
		let reads = records.reads.filter { $0 == Preferences.scope }.count
		store.notifyImport()
		try await waitUntil { records.reads.filter { $0 == Preferences.scope }.count > reads }
		read.release()
		let snapshots = await observing.value
		#expect(await snapshots.status { $0.language == .fixed(.es) }?.language == .fixed(.es))
		#expect(await coach.languagePreference() == .fixed(.es))
		#expect(store.subscriptions == 1)
	}

	private func remoteCoach(sharing store: ImportingRecordLog) async -> Coach {
		await makeCoach(
			transport: FakeModelTransport(),
			store: ImportingRecordLog(
				inner: store.inner, deviceId: DeviceID(rawValue: "remote-phone")))
	}
}
