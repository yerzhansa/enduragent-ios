import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CoachStatusTests {
	@Test func languagePublicationDoesNotRefreshTraining() async throws {
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let coach = await makeCoach(
			transport: FakeModelTransport(), intervals: intervals, store: InMemoryRecordLog())
		try await coach.setLanguage(.fixed(.es))
		let snapshot = try await coach.observedStatus()
		#expect(snapshot.language == .fixed(.es))
		#expect(intervals.calls.isEmpty)
	}

	@Test func activationRefreshesTrainingOnce() async {
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let coach = await makeCoach(
			transport: FakeModelTransport(), intervals: intervals, store: InMemoryRecordLog())
		await coach.lifecycle(.becameActive)
		#expect(intervals.calls.count == 1)
	}

	@Test func languagePublishesWhileTrainingIsBlocked() async throws {
		let gate = Gate()
		let client = GatedProfileIntervals(
			base: FakeIntervalsClient(athleteName: "Ada", ftp: 250), gate: gate)
		let coach = await makeCoach(
			transport: FakeModelTransport(), intervals: client, store: InMemoryRecordLog())
		let snapshots = await coach.observeStatus()
		let refreshing = Task { await coach.lifecycle(.becameActive) }
		defer { gate.release() }
		defer { refreshing.cancel() }
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await gate.waitUntilParked()
			} != nil)
		try await coach.setLanguage(.fixed(.es))
		let chosen = try await snapshots.status { $0.language == .fixed(.es) }
		#expect(chosen?.language == .fixed(.es))
		#expect(client.base.calls.isEmpty)
		gate.release()
		try #require(
			try await beforeDeadline(
				within: .seconds(5),
				onTimeout: {
					refreshing.cancel()
					gate.release()
				}
			) {
				await refreshing.value
			} != nil)
		let refreshed = try await coach.observedStatus()
		#expect(refreshed.language == .fixed(.es))
		guard case .connected(let summary, _) = refreshed.training else {
			Issue.record("Expected the refreshed training snapshot")
			return
		}
		#expect(summary.athleteName == "Ada")
	}

	@Test func consentAndSessionPublishToEverySubscriber() async throws {
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: InMemoryRecordLog(), consent: false)
		let first = await coach.observeStatus()
		let second = await coach.observeStatus()
		#expect(try await first.status(matching: { _ in true })?.needsProviderConsent == true)
		#expect(try await second.status(matching: { _ in true })?.needsProviderConsent == true)
		try await coach.recordConsent()
		let accepted = try #require(try await first.status { _ in true })
		#expect(accepted.providerConsent?.isCurrent == true)
		#expect(accepted.setup == .ready)
		#expect(try await second.status { _ in true } == accepted)
		let session = try SessionSettings.npmDefaults.replacing(
			.contextWindowOverride, with: "64000")
		try await coach.setSession(session)
		#expect(try await first.status(matching: { _ in true })?.session == session)
		#expect(try await second.status(matching: { _ in true })?.session == session)
	}

	@Test func acceptingStoredConsentRepublishesAfterAReadFailure() async throws {
		let records = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let coach = await makeCoach(transport: FakeModelTransport(), store: records)
		records.failFetches = true
		#expect(try await coach.observedStatus().needsProviderConsent)
		let snapshots = await coach.observeStatus()
		records.failFetches = false
		try await coach.recordConsent()
		let accepted = try await snapshots.status { !$0.needsProviderConsent }
		#expect(accepted?.providerConsent?.isCurrent == true)
		#expect(accepted?.setup == .ready)
		let persisted = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.providerConsent])))
		#expect(persisted.records.count == 1)
	}

	@Test func choosingStoredLanguageRepublishesAfterAReadFailure() async throws {
		let records = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let first = await makeCoach(transport: FakeModelTransport(), store: records)
		try await first.setLanguage(.fixed(.es))
		let reopened = await makeCoach(
			transport: FakeModelTransport(), store: records, consent: false)
		records.failFetches = true
		#expect(try await reopened.observedStatus().language == .automatic)
		let snapshots = await reopened.observeStatus()
		records.failFetches = false
		try await reopened.setLanguage(.fixed(.es))
		let chosen = try await snapshots.status { $0.language == .fixed(.es) }
		#expect(chosen?.language == .fixed(.es))
		let persisted = try await records.fetch(
			RecordQuery(scope: .synced([.languagePreference])))
		#expect(persisted.records.count == 1)
	}

	@Test func failedLanguageCommitKeepsThePublishedChoice() async throws {
		let records = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let coach = await makeCoach(transport: FakeModelTransport(), store: records)
		try await coach.setLanguage(.fixed(.fr))
		let snapshots = await coach.observeStatus()
		#expect(try await snapshots.status(matching: { _ in true })?.language == .fixed(.fr))
		try records.failAppends(ofKind: "languagePreference")
		await #expect(throws: PreferenceWriteFailure.notSaved) {
			try await coach.setLanguage(.fixed(.es))
		}
		try await coach.setSession(.npmDefaults)
		#expect(try await snapshots.status(matching: { _ in true })?.language == .fixed(.fr))
	}

	@Test func aLateTrainingRefreshCannotRestoreADisconnectedAccount() async throws {
		let gate = Gate()
		let client = GatedProfileIntervals(
			base: FakeIntervalsClient(athleteName: "Ada", ftp: 250), gate: gate)
		let coach = await makeCoach(
			transport: FakeModelTransport(), intervals: client, store: InMemoryRecordLog())
		let refreshing = Task { await coach.lifecycle(.becameActive) }
		defer { gate.release() }
		defer { refreshing.cancel() }
		try #require(
			try await beforeDeadline(within: .seconds(5)) {
				await gate.waitUntilParked()
			} != nil)
		#expect(await coach.changeTraining(.disconnect) == .disconnected)
		gate.release()
		try #require(
			try await beforeDeadline(
				within: .seconds(5),
				onTimeout: {
					refreshing.cancel()
					gate.release()
				}
			) {
				await refreshing.value
			} != nil)
		#expect(try await coach.observedStatus().training == .unconnected)
	}

}
