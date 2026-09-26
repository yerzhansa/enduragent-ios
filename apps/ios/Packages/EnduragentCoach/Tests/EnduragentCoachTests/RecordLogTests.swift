import Foundation
import Testing

@testable import EnduragentCoach

enum RecordLogKind: String, Sendable, CaseIterable {
	case inMemory
	case swiftData
}

@Suite(.serialized) enum SwiftDataSuites {
	static func makeRecordLog(_ kind: RecordLogKind, deviceId: DeviceID) throws -> any RecordLog {
		switch kind {
		case .inMemory:
			return InMemoryRecordLog(deviceId: deviceId)
		case .swiftData:
			return try makeSwiftDataLog(deviceId: deviceId)
		}
	}

	static func makeSwiftDataLog(deviceId: DeviceID) throws -> SwiftDataRecordLog {
		let root = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-records-\(UUID().uuidString)",
			directoryHint: .isDirectory
		)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return SwiftDataRecordLog(
			deviceId: deviceId,
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: "synced.store")),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: "local.store"))
		)
	}
}

extension SwiftDataSuites {
	@Suite struct RecordLogTests {
		let phoneA = DeviceID(rawValue: "phone-a")
		let phoneB = DeviceID(rawValue: "phone-b")

		@Test(arguments: RecordLogKind.allCases)
		func fetchHonoursEveryQueryField(kind: RecordLogKind) async throws {
			let log = try makeRecordLog(kind, deviceId: phoneA)
			let otherChat = try #require(ChatID(rawValue: "other"))
			let turn = TurnID(ulid: ULID.generate(at: Date(timeIntervalSince1970: 10)))
			try await seed(
				log,
				[
					storedRecord(
						device: phoneA, wall: 10, date: "1998-06-13",
						body: .synced(sampleUser(chatId: .main, text: "main 13", turn: turn))),
					storedRecord(
						device: phoneB, wall: 11, date: "1998-06-14",
						body: .synced(sampleReply(chatId: .main, turn: turn, text: "reply 14"))),
					storedRecord(
						device: phoneA, wall: 12, date: "1998-06-15",
						body: .synced(sampleUser(chatId: otherChat, text: "other 15"))),
					storedRecord(
						device: phoneA, wall: 13, date: "1998-06-14",
						body: .deviceLocal(
							.pendingProposal(
								sampleProposal(
									chatId: .main, nonce: Nonce(),
									expiresAt: Date(timeIntervalSince1970: 899_164_800))))),
				]
			)
			let messages: RecordQuery.Scope = .synced([.userMessage, .turnSettled])

			let all = try await log.fetch(RecordQuery(scope: messages)).records
			#expect(all.map(messageText) == ["main 13", "reply 14", "other 15"])

			let mainOnly = try await log.fetch(RecordQuery(scope: messages, chatId: .main)).records
			#expect(mainOnly.map(messageText) == ["main 13", "reply 14"])

			let byTurn = try await log.fetch(RecordQuery(scope: messages, turn: turn)).records
			#expect(byTurn.map(messageText) == ["main 13", "reply 14"])

			let mid = try await log.fetch(
				RecordQuery(scope: messages, from: "1998-06-14", to: "1998-06-14")
			).records
			#expect(mid.map(messageText) == ["reply 14"])

			let inclusive = try await log.fetch(
				RecordQuery(scope: messages, from: "1998-06-13", to: "1998-06-14")
			).records
			#expect(inclusive.map(messageText) == ["main 13", "reply 14"])

			let writtenByA = try await log.fetch(RecordQuery(scope: messages, writtenBy: phoneA))
				.records
			#expect(writtenByA.map(messageText) == ["main 13", "other 15"])

			let local = try await log.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal])))
				.records
			#expect(local.map(\.deviceId) == [phoneA])
			#expect(kinds(local) == ["pendingProposal"])
		}

		@Test func legacyRowsComeOnlyWhenAsked() async throws {
			let log = InMemoryRecordLog(deviceId: phoneA)
			try await seed(
				log,
				[
					storedRecord(
						device: phoneA, wall: 1, body: legacyUser(chatId: .main, text: "old")),
					storedRecord(
						device: phoneA, wall: 2,
						body: .synced(sampleUser(chatId: .main, text: "new"))),
				]
			)
			let current = try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records
			#expect(current.map(messageText) == ["new"])
			let both = try await log.fetch(
				RecordQuery(scope: .synced([.userMessage], includeLegacy: [.userMessage]))
			).records
			#expect(both.map(messageText) == ["old", "new"])
		}

		@Test func hlcMonotonicUnderFrozenWallClock() throws {
			let frozen = Date(timeIntervalSince1970: 899_164_800)
			var last: HybridLogicalClock?
			var ticks: [HybridLogicalClock] = []
			for _ in 0..<5 {
				let next = HybridLogicalClock.tick(now: frozen, deviceId: phoneA, last: last)
				ticks.append(next)
				last = next
			}
			#expect(ticks[0].logical == 0)
			#expect(ticks.map(\.wallMs).allSatisfy { $0 == ticks[0].wallMs })
			#expect(ticks.map(\.logical) == [0, 1, 2, 3, 4])
			for index in 1..<ticks.count {
				#expect(ticks[index - 1] < ticks[index])
			}
			let later = HybridLogicalClock.tick(
				now: frozen.addingTimeInterval(1),
				deviceId: phoneA,
				last: ticks.last
			)
			let latest = try #require(ticks.last)
			#expect(later.wallMs > latest.wallMs)
			#expect(later.logical == 0)
			#expect(latest < later)
		}
	}
}
