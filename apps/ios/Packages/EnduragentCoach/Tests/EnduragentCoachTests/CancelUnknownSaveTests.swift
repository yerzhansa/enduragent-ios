import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct CancelUnknownSaveTests {
	static let sentence =
		"Cancelled. This workout may still have been saved. Check your calendar."

	enum Access: CaseIterable, Sendable { case online, offline, locked, otherAthlete }

	@Test(arguments: Access.allCases)
	func cancelReleasesBlockWithoutCalendarAccess(access: Access) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock {
			$0.response = .status(502)
			$0.readResponse = .body("[]")
		}
		let memory = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: memory)
		let helper = DurableCalendarWriteTests()
		let fixture = await helper.fixture(url: url)
		let coach = await makeCoach(
			transport: fixture.model, intervals: fixture.client, store: fixture.store,
			secrets: secrets)
		let (turn, approval) = try await helper.proposal(on: coach, model: fixture.model)
		_ = await coach.decide(.approve(approval), in: .main)
		await coach.stop(.main)
		if access == .otherAthlete {
			try secrets.storeIntervalsConnection(
				IntervalsConnection(
					id: ConnectionID(), credential: .apiKey("test-athlete-b"), selection: .keyOwner,
					resolvedAthlete: IntervalsAthleteID(rawValue: "i2002")))
			server.state.withLock { $0.athleteID = "i2002" }
			_ = await coach.decide(.presented(approval.ref), in: .main)
		} else {
			_ = await coach.decide(.checkAgain(approval.ref), in: .main)
		}
		let absent = try #require(await coach.currentSnapshot(.main)?.review)
		let token: ReviewControlToken
		switch absent.controls {
		case .retryRemainingOrCancel(let ready) where access != .otherAthlete: token = ready
		case .cancelOnly(let ready) where access == .otherAthlete: token = ready
		default:
			Issue.record("Expected unknown-save Cancel controls")
			return
		}
		if access == .offline { server.state.withLock { $0.readResponse = .disconnected } }
		if access == .locked {
			memory.fail("intervalsCredential", with: errSecInteractionNotAllowed)
		}
		let calls = server.state.withLock { $0.requests.count }
		#expect(await coach.decide(.cancel(token), in: .main) == .canceled(kept: []))
		#expect(server.state.withLock { $0.requests.count } == calls)
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		let notes = try #require(await coach.currentSnapshot(.main)?.notes.values.flatMap { $0 })
		#expect(notes.map { $0.sentence(in: displayLocale()) } == [Self.sentence])
		#expect(await coach.decide(.cancel(token), in: .main) == .staleControl)
		#expect(await coach.decide(.approve(token), in: .main) == .staleControl)
		#expect(await coach.decide(.retryRemaining(token), in: .main) == .staleControl)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await coach.retry(turn, in: .main)
		}
		memory.fail("intervalsCredential", with: nil)
		let reopened = await makeCoach(
			transport: fixture.model, intervals: fixture.client, store: fixture.store,
			secrets: secrets)
		#expect(await reopened.currentSnapshot(.main)?.review == nil)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await reopened.retry(turn, in: .main)
		}
		let restored = try #require(
			await reopened.currentSnapshot(.main)?.notes.values.flatMap { $0 })
		#expect(restored.map { $0.sentence(in: displayLocale()) } == [Self.sentence])
		server.state.withLock { $0.readResponse = .success }
		let (freshTurn, fresh) = try await helper.proposal(
			on: reopened, model: fixture.model, name: "Fresh")
		#expect(fresh.ref.set != token.ref.set)
		await reopened.stop(.main)
		#expect(freshTurn != turn)
		let savedProposals = try await fixture.store.fetch(
			RecordQuery(scope: .deviceLocal([.pendingProposal]))
		).records
		let identities = savedProposals.compactMap { record -> CalendarWriteID? in
			guard case .deviceLocal(.pendingProposal(let body)) = record.body else { return nil }
			return body.writeID
		}
		#expect(Set(identities).count == 2)
		_ = await reopened.decide(.cancel(fresh), in: .main)
		fixture.model.respond = { _ in
			ScriptedReply([.text("Memory saved."), .finish(reason: .stop)])
		}
		_ = try #require(
			try await beforeDeadline(within: .hangGuard) {
				await reopened.startNewConversation(in: .main)
			})
		let (_, next) = try await helper.proposal(on: reopened, model: fixture.model, name: "Next")
		#expect(next.ref.set != token.ref.set && next.ref.set != fresh.ref.set)
		#expect(await reopened.currentSnapshot(.main)?.notes.isEmpty == true)
		let history = try await reopened.history()
		let archivedRef = try #require(history.first?.id)
		let archive = try #require(try await reopened.archivedConversation(archivedRef))
		#expect(archive.notes.map { $0.sentence(in: displayLocale()) } == [Self.sentence])
		await reopened.stop(.main)
	}
	@Test func failedCancellationMarkerKeepsTheBlockAndReportsStorageFailure() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock {
			$0.response = .status(502)
			$0.readResponse = .body("[]")
		}
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let (fixture, turn, token) = try await cancellable(url: url, store: faults)
		try faults.failAppends(ofKind: "reviewCancelledUnknown")
		let calls = server.state.withLock { $0.requests.count }
		#expect(await fixture.coach.decide(.cancel(token), in: .main) == .storageUnavailable)
		#expect(server.state.withLock { $0.requests.count } == calls)
		#expect(await fixture.coach.currentSnapshot(.main)?.review?.ref == token.ref)
		#expect(await fixture.coach.currentSnapshot(.main)?.notes.isEmpty == true)
		#expect(
			(turnNotice(of: try #require(await fixture.coach.state(of: turn)))?.actions ?? [])
				.isEmpty
		)
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: faults)
		#expect(await reopened.currentSnapshot(.main)?.review?.ref.set == token.ref.set)
		let writes = try await Ledger(
			log: faults,
			clock: FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"),
			diagnostics: DiagnosticsLog(
				clock: FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"))
		)
		.calendarWrites(.main)
		#expect(writes.first?.blocksNewWork == true)
	}

	@Test func importedCancellationAndLateAppliedEvidenceNeverReopenTheReview() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock {
			$0.response = .status(502)
			$0.readResponse = .body("[]")
		}
		let store = ImportingRecordLog()
		let (fixture, turn, token) = try await cancellable(url: url, store: store)
		let otherStore = ImportingRecordLog(
			inner: DeviceAliasLog(inner: store, deviceId: DeviceID(rawValue: "phone-b")))
		let other = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: otherStore)
		let snapshots = ImportSnapshots(await other.observe(.main))
		try await waitUntil { snapshots.latest?.review != nil }
		#expect(await fixture.coach.decide(.cancel(token), in: .main) == .canceled(kept: []))
		otherStore.notifyImport()
		try await waitUntil {
			snapshots.latest?.review == nil && snapshots.latest?.notes.count == 1
		}
		let marker = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.reviewCancelledUnknown]))).records
				.first)
		let original = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.reviewWrite]))).records.last)
		guard case .synced(.reviewWrite(var write)) = original.body else {
			Issue.record("Expected original calendar intent")
			return
		}
		#expect(marker.account == original.account)
		#expect(marker.deviceId == original.deviceId)
		#expect(marker.cause == original.cause)
		write.evidence = .applied(eventID: 1)
		let applied = AthleteRecord(
			ulid: fixedUlid(990), deviceId: original.deviceId,
			hlc: HybridLogicalClock(
				wallMs: marker.hlc.wallMs + 1_000, logical: 0, deviceId: original.deviceId),
			timeZone: original.timeZone, civilDate: original.civilDate, cause: original.cause,
			account: original.account, body: .synced(.reviewWrite(write)))
		let duplicate = AthleteRecord(
			ulid: fixedUlid(991), deviceId: marker.deviceId,
			hlc: HybridLogicalClock(
				wallMs: marker.hlc.wallMs + 2_000, logical: 0, deviceId: marker.deviceId),
			timeZone: marker.timeZone, civilDate: marker.civilDate, cause: marker.cause,
			account: marker.account, body: marker.body)
		try await store.append([applied, duplicate], locality: .synced)
		let before = snapshots.count
		store.notifyImport()
		otherStore.notifyImport()
		try await waitUntil { snapshots.count > before }
		#expect(snapshots.latest?.review == nil)
		#expect(
			snapshots.latest?.notes.values.flatMap { $0 }.map {
				$0.sentence(in: displayLocale())
			} == [Self.sentence])
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await fixture.coach.retry(turn, in: .main)
		}
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: store)
		#expect(await reopened.currentSnapshot(.main)?.review == nil)
		#expect(await reopened.currentSnapshot(.main)?.notes.values.flatMap { $0 }.count == 1)
		#expect(server.posts.count == 1)
	}

	private func cancellable(url: URL, store: any RecordLog) async throws
		-> (CalendarFixture, TurnID, ReviewControlToken)
	{
		let helper = DurableCalendarWriteTests()
		let fixture = await helper.fixture(url: url, store: store)
		let (turn, approval) = try await helper.proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(approval), in: .main)
		await fixture.coach.stop(.main)
		_ = await fixture.coach.decide(.checkAgain(approval.ref), in: .main)
		let review = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel(let token) = review.controls else {
			throw CancellationFixtureFailure()
		}
		return (fixture, turn, token)
	}

}

private struct CancellationFixtureFailure: Error {}
