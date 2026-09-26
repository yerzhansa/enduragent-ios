import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ReplyObservedTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let store = InMemoryRecordLog()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func replyObservedIsWrittenBeforeFirstDeltaIsPublished() async throws {
		transport.script = [.text("Thursday "), .text("is on."), .finish(reason: .stop)]
		let gate = ReplyMarkGate(inner: store)
		let coach = EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: gate, clock: clock)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		var held = gate.held.makeAsyncIterator()
		_ = await held.next()
		let whileHeld = try #require(await coach.currentSnapshot(.main))
		guard case .processing(let processing)? = whileHeld.turns.first?.state else {
			Issue.record("expected processing, got \(String(describing: whileHeld.turns.first))")
			return
		}
		#expect(processing.liveText.isEmpty)
		gate.open()
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(settled) == "Thursday is on.")
		let marks = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.replyObserved]), turn: turn)
		).records
		let claims = try await store.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), turn: turn)
		).records
		#expect(marks.count == 1)
		#expect(marks.first?.cause == claims.first?.cause)
	}

	@Test func replyObservedIsFoldedAfterRelaunch() async throws {
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		let coach = makeCoach()
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		_ = try #require(await coach.settledState(of: turn, in: .main))
		let ledger = Ledger(log: store, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		let synced = try await ledger.read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: .main))
		let local = try await ledger.read(
			RecordQuery(scope: ConversationFold.localScope, chatId: .main))
		let facts = try #require(
			ConversationFold.fold(
				chat: .main, synced: synced.records, local: local.records, device: store.deviceId
			).turn(turn))
		let attempt = try #require(facts.claims.first?.attempt)
		#expect(facts.replyObserved.map(\.attempt) == [attempt])
		#expect(
			TurnLifecycle.writes(
				for: .observeReply(attempt), on: facts, chat: .main, device: store.deviceId,
				mint: { turn }) == .success(.nothing))
	}

	private func makeCoach() -> Coach {
		EnduragentCoachTests.makeCoach(
			transport: transport, intervals: intervals, store: store, clock: clock)
	}
}

private final class ReplyMarkGate: RecordLog, @unchecked Sendable {
	let inner: any RecordLog
	let held: AsyncStream<Void>
	private let entered: AsyncStream<Void>.Continuation
	private let lock = NSLock()
	private var waiting: CheckedContinuation<Void, Never>?
	private var opened = false

	init(inner: any RecordLog) {
		self.inner = inner
		(held, entered) = AsyncStream<Void>.makeStream()
	}

	var deviceId: DeviceID { inner.deviceId }

	var imports: AsyncStream<Void> { inner.imports }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		if batch.contains(where: { $0.body.kind == DeviceLocalKind.replyObserved.rawValue }) {
			entered.yield()
			await withCheckedContinuation { continuation in
				let proceed = lock.withLock {
					if opened {
						return true
					}
					waiting = continuation
					return false
				}
				if proceed {
					continuation.resume()
				}
			}
		}
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	func open() {
		let parked = lock.withLock {
			opened = true
			defer { waiting = nil }
			return waiting
		}
		parked?.resume()
	}
}
