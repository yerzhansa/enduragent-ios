import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test(arguments: [false, true])
	func legacyUnknownCreatesCanOnlyReadTheirOriginalExternalID(found: Bool) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let fixture = await fixture(url: url)
		let (turn, _) = try await proposal(on: fixture.coach, model: fixture.model)
		await fixture.coach.stop(.main)
		let store = try await legacyUnknownStore(from: fixture.store)
		if found {
			server.state.withLock {
				$0.events = [
					[
						"id": .number(7), "name": .string("Strength"),
						"description": .string("Three sets"), "type": .string("WeightTraining"),
						"category": .string("WORKOUT"),
						"start_date_local": .string("1998-06-14T00:00:00"),
						"external_id": .string("cycling-coach:1998-06-14:strength-strength"),
						"tags": .array([.string("cycling-coach")]),
					]
				]
			}
		}
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: store)
		let review = try #require(await reopened.currentSnapshot(.main)?.review)
		#expect(review.controls == .checkAgain(review.ref))
		#expect(await reopened.state(of: turn)?.retryable == false)
		let outcome = await reopened.decide(.checkAgain(review.ref), in: .main)
		if found {
			#expect(
				outcome == .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "7"))]))
			#expect(await reopened.currentSnapshot(.main)?.review == nil)
		} else {
			let pending = try #require(await reopened.currentSnapshot(.main)?.review)
			#expect(pending.controls == .checkAgain(pending.ref))
		}
		#expect(server.writes.isEmpty)
		await #expect(throws: RetryRefusal.alreadyAnswered) {
			try await reopened.retry(turn, in: .main)
		}
	}

	private func legacyUnknownStore(from source: any RecordLog) async throws -> InMemoryRecordLog {
		let store = InMemoryRecordLog(deviceId: source.deviceId)
		let synced = try await source.fetch(RecordQuery(scope: .everySynced))
			.records
		try await store.append(synced, locality: .synced)
		let local = try await source.fetch(
			RecordQuery(scope: .everyDeviceLocal)
		).records
		let proposal = try #require(local.last { $0.body.kind == "pendingProposal" })
		let encoded = try RecordCodec.encode(proposal.body)
		var fields = try JSONValue.parse(String(decoding: encoded.data, as: UTF8.self)).objectFields
		fields.removeValue(forKey: "writeID")
		let legacy = try RecordCodec.decode(
			kind: "pendingProposal", version: 2,
			data: Data(JSONValue.object(fields).canonicalDigestInput().utf8),
			civilDate: proposal.civilDate, ulid: proposal.ulid.rawValue
		).get()
		let retained = AthleteRecord(
			ulid: proposal.ulid, deviceId: proposal.deviceId,
			hlc: proposal.hlc, timeZone: proposal.timeZone, civilDate: proposal.civilDate,
			cause: proposal.cause, account: proposal.account, body: legacy)
		try await store.append(
			local.filter { $0.ulid != proposal.ulid } + [retained], locality: .deviceLocal)
		guard case .deviceLocal(.pendingProposal(let body)) = retained.body else {
			throw RecordDecodeFailure(reason: "expected a retained legacy proposal")
		}
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		guard case .operation(let operation, let attempt) = proposal.cause else {
			throw RecordDecodeFailure(reason: "expected a proposing turn")
		}
		let stamp = OperationStamp(
			operation: operation, attempt: attempt,
			binding: ActionBinding(account: proposal.account, zone: proposal.timeZone))
		_ = try await ledger.commit(
			local: [
				.proposalCleared(
					ProposalClearedBody(
						chatId: .main, nonce: body.nonce, reason: .executed))
			], stamp: stamp)
		let raw =
			"{\"chatId\":\"main\",\"review\":\"\(proposal.ulid.rawValue)\",\"status\":\"unverified\"}"
		let write = try RecordCodec.decode(
			kind: "reviewWrite", version: 2,
			data: Data(raw.utf8), civilDate: proposal.civilDate, ulid: fixedUlid(987).rawValue
		).get()
		guard case .synced(let unknown) = write else {
			throw RecordDecodeFailure(reason: "expected legacy review evidence")
		}
		_ = try await ledger.commit(synced: [unknown], stamp: stamp)
		return store
	}
}
