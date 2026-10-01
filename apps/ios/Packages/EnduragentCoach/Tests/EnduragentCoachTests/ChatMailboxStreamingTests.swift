import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

extension ChatMailboxTests {
	@Test func streamingPublishesLiveTextOnly() async throws {
		let clock = CountingSnapshotClock(base: clock)
		let pacing = HeldClock()
		let transport = FakeModelTransport(clock: pacing)
		transport.respond = ScriptedReply.sequence(
			[.text("Thursday "), .text("is on."), .finish(reason: .stop)],
			deltaDelay: .milliseconds(1), otherwise: transport.respond)
		let store = InMemoryRecordLog()
		_ = try await seedHistory(store, clock: clock, turns: 3, tokens: 60)
		let coach = await makeCoach(transport: transport, store: store, clock: clock)
		var snapshots = await coach.observe(.main).makeAsyncIterator()
		let history = try #require(await snapshots.next())
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		var previous = history
		while let snapshot = await snapshots.next() {
			previous = snapshot
			if case .processing? = snapshot.turns.last?.state { break }
		}
		for text in ["Thursday ", "Thursday is on."] {
			try await pacing.waitUntilHeld(.milliseconds(1))
			let readsBeforeDelta = clock.readCount
			pacing.advance(by: .milliseconds(1))
			var streamed: ChatSnapshot?
			while let snapshot = await snapshots.next() {
				if case .processing? = snapshot.turns.last?.state,
					snapshot.liveReply?.text == text
				{
					streamed = snapshot
					break
				}
			}
			let snapshot = try #require(streamed)
			if previous.liveReply?.text.isEmpty == false {
				#expect(
					clock.readCount == readsBeforeDelta,
					"A text delta must skip snapshot projection")
			}
			#expect(snapshot.liveReply?.turn == turn)
			#expect(snapshot.revision > previous.revision)
			#expect(snapshot.notes == previous.notes)
			#expect(Array(snapshot.turns.dropLast()) == history.turns)
			let reusesRows = previous.turns.withUnsafeBufferPointer { before in
				snapshot.turns.withUnsafeBufferPointer { after in
					before.baseAddress == after.baseAddress
				}
			}
			#expect(reusesRows, "Streaming must reuse the published turn rows")
			previous = snapshot
		}
		try await pacing.waitUntilHeld(.milliseconds(1))
		pacing.advance(by: .milliseconds(1))
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(settled) == "Thursday is on.")
		#expect(Array(previous.turns.dropLast()) == history.turns)
		#expect(await coach.currentSnapshot(.main)?.liveReply == nil)
	}
}

private final class CountingSnapshotClock: Clock {
	private let base: any Clock
	private let reads = Mutex(0)

	init(base: any Clock) {
		self.base = base
	}

	var now: Date {
		reads.withLock { $0 += 1 }
		return base.now
	}

	var readCount: Int { reads.withLock { $0 } }
	var timeZone: TimeZone { base.timeZone }
	var uptime: Duration { base.uptime }

	func sleep(for duration: Duration) async throws {
		try await base.sleep(for: duration)
	}
}
