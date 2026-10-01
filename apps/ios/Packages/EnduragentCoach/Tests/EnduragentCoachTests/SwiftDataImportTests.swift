import CoreData
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct SwiftDataImportTests {
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

		@Test func localTurnDoesNotAddImportReads() async throws {
			let baseline = try await localTurnReads(observingImports: false)
			let observed = try await localTurnReads(observingImports: true)
			#expect(observed == baseline)
		}

		@Test func remoteNotificationBurstRefreshesOnce() async throws {
			let store = ImportingRecordLog(inner: try makeSwiftDataLog(deviceId: DeviceID()))
			let log = BatchRecordingLog(inner: store)
			let coach = await makeCoach(transport: FakeModelTransport(), store: log, clock: clock)
			let snapshots = ImportSnapshots(await coach.observe(.main))
			try await waitUntil { snapshots.latest != nil }
			let reads = log.reads.count
			let count = snapshots.count
			let record = remoteQuestion()
			try await store.append([record], locality: .synced)
			for _ in 0..<10 {
				store.notifyImport()
				try await Task.sleep(for: .milliseconds(10))
			}
			try await waitUntil { snapshots.latest?.turns.first?.athleteText == "Remote question" }
			try await Task.sleep(for: .milliseconds(500))
			#expect(log.reads.count - reads == 4)
			#expect(snapshots.count - count == 1)
			await coach.lifecycle(.willTerminate)
		}

		@Test func duplicateImportedRowsMatchColdLoad() async throws {
			let store = ImportingRecordLog(inner: try makeSwiftDataLog(deviceId: DeviceID()))
			let coach = await makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
			let snapshots = ImportSnapshots(await coach.observe(.main))
			try await waitUntil { snapshots.latest != nil }
			let question = remoteQuestion()
			let turn = try #require(question.body.turn)
			let reply = storedRecord(
				device: question.deviceId, wall: question.hlc.wallMs + 1, ulid: fixedUlid(501),
				body: .synced(sampleReply(chatId: .main, turn: turn, text: "Remote answer")))
			try await store.append([question, question, reply, reply], locality: .synced)
			store.notifyImport()
			try await waitUntil { snapshots.latest?.turns.first?.athleteText == "Remote question" }
			let mailbox = try await coach.mailbox(for: .main)
			let live = await mailbox.conversation
			let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
			let cold = try await ledger.conversation(.main)
			#expect(cold.turn(turn)?.fragments.count == 1)
			#expect(cold.turn(turn)?.settlements.count == 1)
			#expect(live == cold)
			var replayed = cold
			replayed.apply([question, reply], device: store.deviceId)
			#expect(replayed == cold)
			await coach.lifecycle(.willTerminate)
		}

		private func remoteQuestion() -> AthleteRecord {
			let turn = TurnID(ulid: fixedUlid(500))
			return storedRecord(
				device: DeviceID(rawValue: "remote-phone"), wall: 2_000_000_000_000,
				ulid: turn.ulid,
				body: .synced(sampleUser(chatId: .main, text: "Remote question", turn: turn)))
		}

		private func localTurnReads(observingImports: Bool) async throws -> ReadCost {
			let store = try makeSwiftDataLog(deviceId: DeviceID())
			var history: [AthleteRecord] = []
			for index in 0..<2_000 {
				let asked = clock.now.addingTimeInterval(TimeInterval(-20_000 + index * 2))
				let ulid = ULID.generate(at: asked)
				let turn = TurnID(ulid: ulid)
				history.append(
					seededRecord(
						store, at: asked, ulid: ulid,
						body: .synced(sampleUser(chatId: .main, text: "Q", turn: turn))))
				history.append(
					seededRecord(
						store, at: asked.addingTimeInterval(1), ulid: ulid.incremented(),
						body: .synced(sampleReply(chatId: .main, turn: turn, text: "A"))))
			}
			try await store.append(history, locality: .synced)
			let log = BatchRecordingLog(
				inner: observingImports ? store : ImportingRecordLog(inner: store))
			let transport = FakeModelTransport()
			transport.script = [.text("Local answer"), .finish(reason: .stop)]
			let coach = await makeCoach(transport: transport, store: log, clock: clock)
			_ = await coach.currentSnapshot(.main)
			try await Task.sleep(for: .milliseconds(500))
			let reads = log.reads.count
			let rows = log.fetchedRecordCount
			let notifications = Mutex(0)
			let observation = NotificationCenter.default.addObserver(
				forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil
			) { _ in
				notifications.withLock { $0 += 1 }
			}
			defer { NotificationCenter.default.removeObserver(observation) }
			let state = try await coach.sendAndSettle("Local question")
			#expect(replyText(state) == "Local answer")
			try await Task.sleep(for: .seconds(2))
			#expect(notifications.withLock { $0 } > 0)
			let cost = ReadCost(reads: log.reads.count - reads, rows: log.fetchedRecordCount - rows)
			await coach.lifecycle(.willTerminate)
			return cost
		}

		private struct ReadCost: Equatable {
			let reads: Int
			let rows: Int
		}
	}
}
