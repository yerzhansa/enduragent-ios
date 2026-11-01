import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RemovedPlanningKindsTests {
		struct RemovedRecords: Decodable {
			struct Row: Decodable {
				let kind: String
				let body: String
			}

			let bodyVersion: Int
			let rows: [Row]
			let operations: [String]

			static func load() throws -> RemovedRecords {
				try JSONDecoder().decode(
					RemovedRecords.self, from: try fixtureData("removed-planning-records"))
			}
		}

		let phoneA = DeviceID(rawValue: "phone-a")

		@Test func rowsOfTheDeletedPlanningKindsReadAsNewerKinds() async throws {
			let removed = try RemovedRecords.load()
			try #require(removed.rows.count == 5)
			let root = try TestTemporaryFolders.make()
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let context = ModelContext(
				try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")
				).container)
			var expected: Set<SkippedRow> = []
			for (index, row) in removed.rows.enumerated() {
				let stored = try StoredAthleteRecord(
					record: storedRecord(
						device: phoneA, wall: Int64(index + 1), ulid: fixedUlid(810 + index),
						cause: .operation(
							.turn(TurnID(ulid: fixedUlid(820 + index))),
							AttemptID(ulid: fixedUlid(830 + index))),
						body: .deviceLocal(sampleLocal())))
				stored.kind = row.kind
				stored.bodyVersion = removed.bodyVersion
				stored.body = Data(row.body.utf8)
				context.insert(stored)
				expected.insert(.newerKind(kind: row.kind, ulid: stored.ulid))
			}
			try context.save()
			let log = try makeSwiftDataLog(deviceId: phoneA, directory: root)
			let kept = storedRecord(
				device: phoneA, wall: 10, ulid: fixedUlid(840), body: .deviceLocal(sampleLocal()))
			try await log.append([kept], locality: .deviceLocal)

			let page = try await log.fetch(RecordQuery(scope: .everyDeviceLocal))

			#expect(page.records == [kept])
			#expect(Set(page.skipped) == expected)
			let coach = await makeCoach(transport: FakeModelTransport(), store: log)
			let snapshot = try await coach.recordSyncProbe().snapshot()
			#expect(snapshot.skipped == removed.rows.count)
			#expect(snapshot.rows.contains { $0.id == kept.ulid.rawValue })
		}

		@Test func planningDeviceIsReadOnlyAtItsV1Version() async throws {
			let unwrapped = Data(
				#"{"activatedAt":897984000,"planUlid":"\#(fixedUlid(800).rawValue)","planningDeviceId":"phone-a"}"#
					.utf8)
			#expect(
				RecordCodec.decode(
					kind: "planningDevice", version: 2, data: unwrapped, civilDate: "1998-06-15",
					ulid: "row-plan")
					== .failure(.newerVersion(kind: "planningDevice", version: 2, ulid: "row-plan"))
			)
			let body = RecordBody.legacy(
				.planningDevice(
					PlanningDeviceBody(
						planningDeviceId: phoneA, planUlid: fixedUlid(800),
						activatedAt: Date(timeIntervalSince1970: 897_984_000))))
			let log = try makeSwiftDataLog(deviceId: phoneA)

			await #expect(throws: RecordDecodeFailure.self) {
				try await log.append(
					[storedRecord(device: phoneA, wall: 1, body: body)], locality: .synced)
			}

			let stored = try await log.fetch(RecordQuery(scope: .everySynced))
			#expect(stored.records.isEmpty)
			#expect(stored.skipped.isEmpty)
		}

		@Test func aRemovedOperationStampMakesItsRowMalformed() async throws {
			let removed = try RemovedRecords.load()
			try #require(removed.operations.count == 2)
			let root = try TestTemporaryFolders.make()
			try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
			let stamp = RecordCause.operation(
				.turn(TurnID(ulid: fixedUlid(870))), AttemptID(ulid: fixedUlid(871)))
			let context = ModelContext(
				try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local.store")
				).container)
			var expected: Set<SkippedRow> = []
			for (index, operation) in removed.operations.enumerated() {
				let stored = try StoredAthleteRecord(
					record: storedRecord(
						device: phoneA, wall: Int64(index + 1), ulid: fixedUlid(850 + index),
						cause: stamp, body: .deviceLocal(sampleLocal())))
				stored.operation = operation
				context.insert(stored)
				expected.insert(.malformed(kind: "replyObserved", ulid: stored.ulid))
			}
			try context.save()
			let log = try makeSwiftDataLog(deviceId: phoneA, directory: root)
			let kept = storedRecord(
				device: phoneA, wall: 10, ulid: fixedUlid(860), cause: stamp,
				body: .deviceLocal(sampleLocal()))
			try await log.append([kept], locality: .deviceLocal)

			let page = try await log.fetch(RecordQuery(scope: .deviceLocal([.replyObserved])))

			#expect(page.records == [kept])
			#expect(Set(page.skipped) == expected)
		}
	}
}
