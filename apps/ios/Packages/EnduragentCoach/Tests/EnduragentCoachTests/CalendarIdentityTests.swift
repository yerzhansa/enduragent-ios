import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test func regenerationBeforeDispatchPreservesTheWriteIdentity() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let fixture = await fixture(url: url)
		let (turn, _) = try await proposal(on: fixture.coach, model: fixture.model)
		await fixture.coach.stop(.main)
		let first = try await proposalBytes(in: fixture.store)
		let writeID = first.objectFields["writeID"]?.stringValue
		#expect(writeID != nil)
		fixture.model.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments:
						#"{"date":"1998-06-14","name":"Renamed workout","description":"Four sets"}"#
				),
				.finish(reason: .toolCalls), .text("Revised."), .finish(reason: .stop),
			], for: .chat, otherwise: fixture.model.respond)
		try await fixture.coach.retry(turn, in: .main)
		_ = try #require(await fixture.coach.settledState(of: turn, in: .main))
		let second = try await proposalBytes(in: fixture.store)
		#expect(second.objectFields["writeID"]?.stringValue == writeID)
		let review = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.presented(review.ref), in: .main)
		let token = try #require(await fixture.coach.currentSnapshot(.main)?.review?.token)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		#expect(server.posts.count == 1)
		#expect(server.posts.first?.body.objectFields["uid"]?.stringValue == writeID)
		#expect(server.events.first?["name"]?.stringValue == "Renamed workout")
	}

	@Test func twoIntendedSameDayWorkoutsHaveDifferentWriteIdentities() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let fixture = await fixture(url: url)
		for _ in 0..<2 {
			let (_, token) = try await proposal(on: fixture.coach, model: fixture.model)
			_ = await fixture.coach.decide(.approve(token), in: .main)
			await fixture.coach.stop(.main)
		}
		#expect(server.posts.count == 2)
		#expect(server.events.count == 2)
		let identifiers = server.posts.compactMap { $0.body.objectFields["uid"]?.stringValue }
		#expect(Set(identifiers).count == 2)
	}

	@Test func anImportedUnknownWriteBlocksRegenerationAndCannotDispatch() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(502) }
		let fixture = await fixture(url: url)
		let imported = ImportingRecordLog(
			inner: DeviceAliasLog(
				inner: fixture.store, deviceId: DeviceID(rawValue: "second-phone")))
		let second = await makeCoach(
			transport: FakeModelTransport(),
			intervals: fixture.client, store: imported)
		let snapshots = ImportSnapshots(await second.observe(.main))
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		imported.notifyImport()
		try await waitUntil { snapshots.latest?.turns.first?.id == turn }
		let state = try #require(snapshots.latest?.turns.first?.state)
		#expect((turnNotice(of: state)?.actions ?? []).isEmpty)
		let review = try #require(snapshots.latest?.review)
		#expect(review.authority == .otherDevice)
		#expect(review.controls == .none)
		#expect(
			await second.decide(.checkAgain(review.ref), in: .main).notice?.key
				== Catalog.reviewWriteReadFailed)
		await #expect(throws: RetryRefusal.self) { try await second.retry(turn, in: .main) }
		let own = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(own.ref), in: .main)
		imported.notifyImport()
		try await waitUntil { snapshots.latest?.review == nil }
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
		let reopened = await makeCoach(
			transport: FakeModelTransport(),
			intervals: fixture.client, store: imported)
		#expect(await second.currentSnapshot(.main) == reopened.currentSnapshot(.main))
	}

	private func proposalBytes(in store: any RecordLog) async throws -> JSONValue {
		let records = try await store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal])))
		let record = try #require(records.records.last)
		let encoded = try RecordCodec.encode(record.body)
		return try JSONValue.parse(String(decoding: encoded.data, as: UTF8.self))
	}
}
