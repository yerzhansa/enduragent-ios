import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct CalendarRecoveryNoticeTests {
	@Test(arguments: [false, true])
	func reopenedUnknownWriteStorageFailureDoesNotInviteRetry(approving: Bool) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(502) }
		let helpers = DurableCalendarWriteTests()
		let fixture = await helpers.fixture(url: url)
		let (_, token) = try await helpers.proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		let faults = FaultInjectingRecordLog(wrapping: fixture.store)
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: faults)
		faults.failFetches = true
		let decision: ReviewDecision = approving ? .approve(token) : .checkAgain(pending.ref)
		let outcome = await reopened.decide(decision, in: .main)
		#expect(outcome.notice?.key == Catalog.reviewWriteReadFailed)
		faults.failFetches = false
		let restored = try #require(await reopened.currentSnapshot(.main)?.review)
		#expect(
			await reopened.decide(.checkAgain(restored.ref), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
	}

	@Test func lockedRecoveryNeverClaimsNothingChanged() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(502) }
		let helpers = DurableCalendarWriteTests()
		let fixture = await helpers.fixture(url: url)
		let memory = FixtureSecretStoreBacking()
		let coach = await makeCoach(
			transport: fixture.model, intervals: fixture.client, store: fixture.store,
			secrets: keyedSecrets(backing: memory))
		let (turn, token) = try await helpers.proposal(on: coach, model: fixture.model)
		_ = await coach.decide(.approve(token), in: .main)
		await coach.stop(.main)
		let pending = try #require(await coach.currentSnapshot(.main)?.review)
		memory.fail("intervalsCredential", with: errSecInteractionNotAllowed)
		let outcome = await coach.decide(.checkAgain(pending.ref), in: .main)
		let notice = try #require(outcome.notice)
		#expect(notice.key == Catalog.reviewWriteReadFailed)
		#expect(!notice.sentence(in: LanguageTag.en.phrasebook).contains("nothing was changed"))
		#expect(server.events.count == 1)
		#expect(server.posts.count == 1)
		#expect(turnNotice(of: try #require(await coach.state(of: turn)))?.action == nil)
	}

	@Test func landedWritePersistenceFailureDoesNotSuggestTryAgain() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let gate = Gate()
		defer { gate.release() }
		let held = HeldCalendarConfirmationLog(inner: faults, gate: gate)
		let helpers = DurableCalendarWriteTests()
		let fixture = await helpers.fixture(url: url, store: held)
		let (turn, token) = try await helpers.proposal(on: fixture.coach, model: fixture.model)
		let approval = Task { await fixture.coach.decide(.approve(token), in: .main) }
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approval.cancel()
					gate.release()
				}
			) {
				await gate.reached.first { _ in true } != nil
			} == true,
			"Calendar confirmation fixture did not park within five seconds")
		#expect(server.events.count == 1)
		try faults.failAppends(ofKind: "reviewApplied")
		gate.release()
		let outcome = try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approval.cancel()
					gate.release()
				}
			) { await approval.value },
			"Calendar approval did not finish within five seconds")
		let notice = try #require(outcome.notice)
		#expect(notice.key == Catalog.reviewWritePending)
		#expect(!notice.sentence(in: LanguageTag.en.phrasebook).contains("Please try again"))
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(turnNotice(of: try #require(await fixture.coach.state(of: turn)))?.action == nil)
		#expect(server.posts.count == 1)
	}

	@Test(arguments: [false, true])
	func cancelingAnAbsentWriteLeavesALastingNoteWithoutErasingDispatch(storageReadFails: Bool)
		async throws
	{
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .heldBeforeCommit }
		let helpers = DurableCalendarWriteTests()
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let fixture = await helpers.fixture(url: url, store: faults)
		let (turn, token) = try await helpers.proposal(on: fixture.coach, model: fixture.model)
		let approval = Task { await fixture.coach.decide(.approve(token), in: .main) }
		try await waitUntil { server.posts.count == 1 }
		approval.cancel()
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approval.cancel()
					server.release()
				}
			) { await approval.value } != nil,
			"Calendar approval did not finish within five seconds")
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
		let absent = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel(let token) = absent.controls else {
			Issue.record("expected approved-write recovery controls")
			return
		}
		if storageReadFails {
			faults.failFetches = true
			let outcome = await fixture.coach.decide(.cancel(token), in: .main)
			#expect(outcome == .storageUnavailable)
			faults.failFetches = false
		}
		let canceled = await fixture.coach.decide(.cancel(token), in: .main)
		#expect(canceled == .canceled(kept: []))
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: fixture.store)
		#expect(await reopened.currentSnapshot(.main)?.review == nil)
		#expect(
			await reopened.currentSnapshot(.main)?.notes.values.flatMap { $0 }.map {
				$0.sentence(in: LanguageTag.en.phrasebook)
			} == [CancelUnknownSaveTests.sentence])
		server.release()
		#expect(await reopened.decide(.checkAgain(absent.ref), in: .main) == .staleControl)
		#expect(turnNotice(of: try #require(await reopened.state(of: turn)))?.action == nil)
		#expect(await reopened.currentSnapshot(.main)?.review == nil)
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
	}

	@Test func failedRepeatIntentCommitSendsNoAdditionalPOST() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .heldBeforeCommit }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let helpers = DurableCalendarWriteTests()
		let fixture = await helpers.fixture(url: url, store: faults)
		let (_, token) = try await helpers.proposal(on: fixture.coach, model: fixture.model)
		let approval = Task { await fixture.coach.decide(.approve(token), in: .main) }
		try await waitUntil { server.posts.count == 1 }
		approval.cancel()
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					approval.cancel()
					server.release()
				}
			) { await approval.value } != nil,
			"Calendar approval did not finish within five seconds")
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
		let absent = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel(let token) = absent.controls else {
			Issue.record("expected approved-write recovery controls")
			return
		}
		try faults.failAppends(ofKind: "reviewWrite")
		let outcome = await fixture.coach.decide(.retryRemaining(token), in: .main)
		#expect(outcome.notice?.key == Catalog.reviewWriteReadFailed)
		#expect(server.posts.count == 1)
		#expect(server.events.isEmpty)
	}
}

private struct HeldCalendarConfirmationLog: RecordLog {
	let inner: FaultInjectingRecordLog
	let gate: Gate
	var deviceId: DeviceID { inner.deviceId }
	var imports: AsyncStream<Void> { inner.imports }

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		if batch.contains(where: {
			if case .synced(.reviewWrite(let write)) = $0.body { return write.evidence.applied }
			return false
		}) {
			await gate.wait()
		}
		try await inner.append(batch, locality: locality)
	}
}
