import Foundation
import Testing

@testable import EnduragentCoach

extension ChatMailboxTests {
	@Test(arguments: [false, true])
	func failedSettlementKeepsExactReplyAfterRecovery(recoverWithNextSave: Bool) async throws {
		let transport = FakeModelTransport()
		transport.script = [
			.text("Keep Thursday easy.\n45 minutes, exactly."), .finish(reason: .stop),
		]
		let store = InMemoryRecordLog()
		let faults = FaultInjectingRecordLog(wrapping: store)
		try faults.failAppends(ofKind: "turnSettled")
		let coach = await makeCoach(transport: transport, store: faults, clock: clock)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		let reply = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(reply) == "Keep Thursday easy.\n45 minutes, exactly.")
		#expect(
			await coach.currentSnapshot(.main)?.storageNotice == Catalog.chatNoticeSettlementUnsaved
		)
		let journal = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.pendingSettlement]), turn: turn))
		let pending = try #require(journal.records.first?.pendingSettlement)
		if recoverWithNextSave {
			faults.allowAppends(ofKind: "turnSettled")
			_ = try await coach.send(draft("Thanks"), to: .main)
		}
		let reopened = await makeCoach(transport: transport, store: store, clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn) == reply)
		let saved = try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn))
		#expect(saved.records == [pending])
		#expect(await reopened.currentSnapshot(.main)?.storageNotice == nil)
		await reopened.retryRecordStorage(in: .main)
		let again = await makeCoach(transport: transport, store: store, clock: clock)
		#expect(await again.state(of: turn) == reply)
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.turnSettled]), turn: turn)).records
				== [pending])
	}
}

extension SingleProposalReviewsTests {
	@Test func failedReviewRefreshKeepsDisabledCardUntilSuccessfulRead() async throws {
		let faults = FaultInjectingRecordLog(wrapping: records)
		let coach = await gatedCoach(log: faults, client: ada)
		let token = try await presentedToken(on: coach)
		let before = try #require(await coach.currentSnapshot(.main)?.review)
		faults.failFetches = true
		_ = await coach.decide(.presented(token.ref), in: .main)
		let failed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(failed.cards == before.cards)
		#expect(failed.ref == before.ref)
		#expect(failed.controls == .none)
		#expect(failed.notice?.kind == .storageUnavailable)
		#expect(failed.notice?.key == Catalog.reviewReadFailure)
		faults.failFetches = false
		await coach.retryRecordStorage(in: .main)
		#expect(await coach.currentSnapshot(.main)?.review == before)
		_ = await coach.decide(.cancel(token), in: .main)
		#expect(await coach.currentSnapshot(.main)?.review == nil)
	}
}

extension SwiftDataSuites {
	@Test static func failedSettlementSurvivesReopeningDiskStore() async throws {
		let directory = FileManager.default.temporaryDirectory.appending(path: "p55-\(UUID())")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer {
			do { try FileManager.default.removeItem(at: directory) } catch { Issue.record(error) }
		}
		func open() throws -> SwiftDataRecordLog {
			try SwiftDataRecordLog(
				deviceId: DeviceID(rawValue: "p55-device"),
				synced: ModelContainerHandle.withoutCloudKit(
					storeURL: directory.appending(path: "synced.store")),
				local: ModelContainerHandle.withoutCloudKit(
					storeURL: directory.appending(path: "local.store")))
		}
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		let transport = FakeModelTransport()
		transport.script = [.text("Exactly 45 minutes.\nEasy pace."), .finish(reason: .stop)]
		let faults = FaultInjectingRecordLog(wrapping: try open())
		try faults.failAppends(ofKind: "turnSettled")
		let coach = await makeCoach(transport: transport, store: faults, clock: clock)
		let turn = try #require(try await coach.send(draft("Tomorrow?"), to: .main).acceptedTurn)
		let reply = try #require(await coach.settledState(of: turn, in: .main))
		await coach.lifecycle(.willTerminate)
		let reopened = await makeCoach(transport: transport, store: try open(), clock: clock)
		await reopened.lifecycle(.becameActive)
		#expect(await reopened.state(of: turn) == reply)
		#expect(
			await reopened.transcript(.main) == ["Tomorrow?", "Exactly 45 minutes.\nEasy pace."])
		#expect(await reopened.currentSnapshot(.main)?.storageNotice == nil)
		#expect(transport.requests.count == 1)
	}
}
