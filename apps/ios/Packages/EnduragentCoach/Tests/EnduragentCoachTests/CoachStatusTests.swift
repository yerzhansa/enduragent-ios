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
		let gate = CredentialProfileGate()
		let client = GatedProfileIntervals(
			base: FakeIntervalsClient(athleteName: "Ada", ftp: 250), gate: gate)
		let coach = await makeCoach(
			transport: FakeModelTransport(), intervals: client, store: InMemoryRecordLog())
		let snapshots = await coach.observeStatus()
		let refreshing = Task { await coach.lifecycle(.becameActive) }
		await gate.waitUntilEntered()
		try await coach.setLanguage(.fixed(.es))
		let chosen = await snapshots.status { $0.language == .fixed(.es) }
		#expect(chosen?.language == .fixed(.es))
		#expect(client.base.calls.isEmpty)
		await gate.release()
		await refreshing.value
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
		var first = await coach.observeStatus().makeAsyncIterator()
		var second = await coach.observeStatus().makeAsyncIterator()
		#expect(await first.next()?.needsProviderConsent == true)
		#expect(await second.next()?.needsProviderConsent == true)
		try await coach.recordConsent()
		let accepted = try #require(await first.next())
		#expect(accepted.providerConsent?.isCurrent == true)
		#expect(accepted.setup == .ready)
		#expect(await second.next() == accepted)
		let session = try SessionSettings.npmDefaults.replacing(
			.contextWindowOverride, with: "64000")
		try await coach.setSession(session)
		#expect(await first.next()?.session == session)
		#expect(await second.next()?.session == session)
	}

	@Test func failedLanguageCommitKeepsThePublishedChoice() async throws {
		let records = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let coach = await makeCoach(transport: FakeModelTransport(), store: records)
		try await coach.setLanguage(.fixed(.fr))
		var snapshots = await coach.observeStatus().makeAsyncIterator()
		#expect(await snapshots.next()?.language == .fixed(.fr))
		try records.failAppends(ofKind: "languagePreference")
		await #expect(throws: PreferenceWriteFailure.notSaved) {
			try await coach.setLanguage(.fixed(.es))
		}
		try await coach.setSession(.npmDefaults)
		#expect(await snapshots.next()?.language == .fixed(.fr))
	}

	@Test func aLateTrainingRefreshCannotRestoreADisconnectedAccount() async throws {
		let gate = CredentialProfileGate()
		let client = GatedProfileIntervals(
			base: FakeIntervalsClient(athleteName: "Ada", ftp: 250), gate: gate)
		let coach = await makeCoach(
			transport: FakeModelTransport(), intervals: client, store: InMemoryRecordLog())
		let refreshing = Task { await coach.lifecycle(.becameActive) }
		await gate.waitUntilEntered()
		#expect(await coach.changeTraining(.disconnect) == .disconnected)
		await gate.release()
		await refreshing.value
		#expect(try await coach.observedStatus().training == .unconnected)
	}

}
