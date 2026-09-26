import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct MemoryFlushTests {
	let clock = FixedClock(now: "1998-06-13T12:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func flushUsesOnlyMemoryWriteAndLedgerAppend() async throws {
		let transport = FakeModelTransport()
		transport.script = [
			.toolCall(
				name: "ledger_append",
				arguments:
					#"{"kind":"decision","date":"1998-06-13","text":"Rides with a group on Saturdays"}"#
			),
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		let store = InMemoryRecordLog()
		let turn = TurnID(ulid: fixedUlid(1))
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId,
					wall: 1,
					body: .synced(
						sampleUser(
							chatId: .main, text: "Remember that I ride with a group on Saturdays",
							turn: turn))
				),
				storedRecord(
					device: store.deviceId,
					wall: 2,
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Noted."))
				),
			]
		)
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.flush(
			trigger: .softThreshold, chatId: .main, transport: transport, access: testAccess)
		#expect(transport.requests.count >= 1)
		#expect(transport.requests[0].tools.map(\.name) == [.memoryWrite, .ledgerAppend])
		let hits = try await memory.query(
			from: "1998-06-13", to: "1998-06-13", contains: "Saturdays")
		#expect(hits.count == 1)
	}

	@Test func softThresholdFlushIsQueuedAfterFinished() async throws {
		let transport = FakeModelTransport()
		transport.script = [
			.text("Noted."),
			.finish(reason: .stop),
			.toolCall(
				name: "ledger_append",
				arguments: #"{"kind":"decision","date":"1998-06-13","text":"Keep Saturdays free"}"#
			),
			.finish(reason: .toolCalls),
			.finish(reason: .stop),
		]
		let store = InMemoryRecordLog()
		let coach = makeCoach(transport: transport, store: store, clock: clock)
		let settled = try await coach.sendAndSettle("Remember Saturdays")
		#expect(replyText(settled) == "Noted.")
		let eventsAtSettle = try await store.fetch(RecordQuery(scope: .synced([.ledgerEvent])))
			.records
		#expect(eventsAtSettle.isEmpty)
		await coach.waitForMemoryFlush()
		let hits = try await coach.memory.query(
			from: "1998-06-13", to: "1998-06-13", contains: "Saturdays")
		#expect(hits.count == 1)
	}

	@Test func staleResetFlushPendingConsumedOnce() async throws {
		let transport = FakeModelTransport()
		transport.script = [
			.finish(reason: .stop),
			.finish(reason: .stop),
			.finish(reason: .stop),
		]
		let store = InMemoryRecordLog()
		let first = storedRecord(
			device: store.deviceId,
			wall: 1,
			body: .deviceLocal(
				.flushPending(
					FlushPendingBody(chatId: .main, trigger: .staleReset, messageUlids: [])))
		)
		let second = storedRecord(
			device: store.deviceId,
			wall: 2,
			body: .deviceLocal(
				.flushPending(
					FlushPendingBody(chatId: .main, trigger: .staleReset, messageUlids: [])))
		)
		try await seed(store, [first, second])
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.flush(
			trigger: .staleReset, chatId: .main, transport: transport, access: testAccess)
		try await memory.flush(
			trigger: .staleReset, chatId: .main, transport: transport, access: testAccess)
		let consumed = try await store.fetch(RecordQuery(scope: .synced([.provenance]))).records
			.compactMap {
				record -> String? in
				guard case .synced(.provenance(let body)) = record.body else { return nil }
				return body.key
			}
		#expect(
			consumed.filter { $0.hasPrefix(MemoryFlushPolicy.consumedFlushKeyPrefix) }.count == 2)
		#expect(consumed.contains(MemoryFlushPolicy.consumedFlushKeyPrefix + first.ulid.rawValue))
		#expect(consumed.contains(MemoryFlushPolicy.consumedFlushKeyPrefix + second.ulid.rawValue))
	}

	@Test func flushCapsAtFiveSteps() async throws {
		let transport = FakeModelTransport()
		var script: [ScriptedEvent] = []
		for _ in 0..<6 {
			script.append(
				.toolCall(
					name: "ledger_append",
					arguments: #"{"kind":"decision","date":"1998-06-13","text":"Hold volume"}"#
				)
			)
			script.append(.finish(reason: .toolCalls))
		}
		script.append(.finish(reason: .stop))
		transport.script = script
		let store = InMemoryRecordLog()
		let turn = TurnID(ulid: fixedUlid(1))
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId, wall: 1,
					body: .synced(sampleUser(chatId: .main, text: "note", turn: turn))),
				storedRecord(
					device: store.deviceId, wall: 2,
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Noted."))),
			]
		)
		let memory = Memory(
			ledger: Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock)
		try await memory.flush(
			trigger: .trim, chatId: .main, transport: transport, access: testAccess)
		#expect(transport.requests.count == MemoryFlushPolicy.maxSteps)
		#expect(
			transport.requests.allSatisfy { $0.tools.map(\.name) == [.memoryWrite, .ledgerAppend] })
	}
}
