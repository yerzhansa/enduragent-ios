import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

let quickWindow = CoalescingPolicy(window: .milliseconds(20))

func makeCoach(
	transport: FakeModelTransport,
	intervals: FakeIntervalsClient = FakeIntervalsClient(athleteName: "Ada", ftp: 250),
	store: any RecordLog,
	clock: any Clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"),
	coalescing: CoalescingPolicy = quickWindow
) -> Coach {
	Coach(
		sport: .cycling,
		transport: transport,
		intervals: intervals,
		store: store,
		clock: clock,
		language: .init(ui: .en, coachReply: nil),
		coalescing: coalescing
	)
}

func draft(_ text: String) -> Draft {
	Draft(id: DraftID(), text: text)
}

extension Coach {
	func sendAndSettle(
		_ text: String, in chat: ChatID = .main, within limit: Duration = .seconds(30)
	) async throws -> TurnState {
		let turn = try #require(try await send(draft(text), to: chat).acceptedTurn)
		return try #require(await settledState(of: turn, in: chat, within: limit))
	}

	func waitUntilProcessing(_ turn: TurnID, in chat: ChatID = .main) async {
		for await snapshot in await observe(chat) {
			if case .processing? = snapshot.turns.first(where: { $0.id == turn })?.state {
				return
			}
		}
	}
}

func refusal(_ retry: @Sendable () async throws(RetryRefusal) -> Void) async -> RetryRefusal? {
	do {
		try await retry()
		return nil
	} catch {
		return error
	}
}

func replyText(_ state: TurnState) -> String? {
	guard case .completed(let completed) = state, case .model(let text) = completed.reply else {
		return nil
	}
	return text
}

func failure(_ state: TurnState) -> CoachFailure? {
	guard case .failed(let failed) = state else { return nil }
	return failed.failure
}

final class BatchRecordingLog: RecordLog, @unchecked Sendable {
	let inner: any RecordLog
	private(set) var batches: [[String]] = []

	init(inner: any RecordLog) {
		self.inner = inner
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		batches.append(batch.map(\.body.kind))
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class SlowAppendLog: RecordLog, Sendable {
	let inner: any RecordLog
	let delay: Duration

	init(inner: any RecordLog, delay: Duration) {
		self.inner = inner
		self.delay = delay
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await Task.sleep(for: delay)
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}

final class HeldAppendLog: RecordLog, Sendable {
	let inner: any RecordLog
	let kind: String
	let occurrence: Int
	let reached: AsyncStream<Void>
	private let reachedContinuation: AsyncStream<Void>.Continuation
	private let state = Mutex<(seen: Int, held: CheckedContinuation<Void, Never>?)>((0, nil))

	init(inner: any RecordLog, holding kind: String, occurrence: Int) {
		self.inner = inner
		self.kind = kind
		self.occurrence = occurrence
		(reached, reachedContinuation) = AsyncStream.makeStream()
	}

	var deviceId: DeviceID { inner.deviceId }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		let hold = state.withLock { current -> Bool in
			guard batch.contains(where: { $0.body.kind == kind }) else { return false }
			current.seen += 1
			return current.seen == occurrence
		}
		if hold {
			await withCheckedContinuation { continuation in
				state.withLock { $0.held = continuation }
				reachedContinuation.yield()
			}
		}
		try await inner.append(batch, locality: locality)
	}

	func release() {
		state.withLock { current in
			current.held?.resume()
			current.held = nil
		}
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		try await inner.fetch(query)
	}

	var imports: AsyncStream<Void> { inner.imports }
}
