import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(2))) struct CalendarRecoveryNoticeTests {
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
		#expect(await coach.state(of: turn)?.retryable == false)
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
		await gate.waitUntilParked()
		#expect(server.events.count == 1)
		try faults.failAppends(ofKind: "reviewApplied")
		gate.release()
		let outcome = await approval.value
		let notice = try #require(outcome.notice)
		#expect(notice.key == Catalog.reviewWritePending)
		#expect(!notice.sentence(in: LanguageTag.en.phrasebook).contains("Please try again"))
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(await fixture.coach.state(of: turn)?.retryable == false)
		#expect(server.posts.count == 1)
	}

	@Test func cancelingAnAbsentWriteStopsRepetitionWithoutErasingDispatch() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .heldBeforeCommit }
		let helpers = DurableCalendarWriteTests()
		let fixture = await helpers.fixture(url: url)
		let (turn, token) = try await helpers.proposal(on: fixture.coach, model: fixture.model)
		let approval = Task { await fixture.coach.decide(.approve(token), in: .main) }
		try await waitUntil { server.posts.count == 1 }
		approval.cancel()
		_ = await approval.value
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
		let absent = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel(let token) = absent.controls else {
			Issue.record("expected approved-write recovery controls")
			return
		}
		let canceled = await fixture.coach.decide(.cancel(token), in: .main)
		#expect(canceled.notice?.key == Catalog.reviewWritePending)
		let retained = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(retained.controls == .checkAgain(retained.ref))
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: fixture.store)
		let restored = try #require(await reopened.currentSnapshot(.main)?.review)
		#expect(restored.controls == .checkAgain(restored.ref))
		server.release()
		#expect(
			await reopened.decide(.checkAgain(restored.ref), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(await reopened.state(of: turn)?.retryable == false)
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
		_ = await approval.value
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
