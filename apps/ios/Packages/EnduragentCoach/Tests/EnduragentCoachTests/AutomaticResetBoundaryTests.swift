import Foundation
import Testing

@testable import EnduragentCoach

extension AutomaticResetTests {
	@Test func staleResetLeavesALaterAnsweredTurnInTheNewConversation() async throws {
		let clock = FixedClock(now: "1998-06-16T09:00:00+02:00", timeZone: "Europe/Amsterdam")
		let earlier = TurnID(ulid: fixedUlid(1))
		let retried = TurnID(ulid: fixedUlid(2))
		let later = TurnID(ulid: fixedUlid(3))
		let base = clock.now.addingTimeInterval(-14 * 3_600)
		let earlierQuestion = ULID.generate(at: base)
		let earlierReply = ULID.generate(at: base.addingTimeInterval(60))
		let retriedQuestion = ULID.generate(at: base.addingTimeInterval(3_600))
		let laterQuestion = ULID.generate(at: base.addingTimeInterval(3_900))
		let laterReply = ULID.generate(at: base.addingTimeInterval(3_960))
		try await seed(
			store,
			[
				seededRecord(
					store, at: base, ulid: earlierQuestion,
					body: .synced(
						sampleUser(chatId: .main, text: "Earlier question", turn: earlier))),
				seededRecord(
					store, at: base.addingTimeInterval(60), ulid: earlierReply,
					body: .synced(sampleReply(chatId: .main, turn: earlier, text: "Earlier reply"))),
				seededRecord(
					store, at: base.addingTimeInterval(3_600), ulid: retriedQuestion,
					body: .synced(
						sampleUser(chatId: .main, text: "Retried question", turn: retried))),
				seededRecord(
					store, at: base.addingTimeInterval(3_900), ulid: laterQuestion,
					body: .synced(sampleUser(chatId: .main, text: "Later question", turn: later))),
				seededRecord(
					store, at: base.addingTimeInterval(3_960), ulid: laterReply,
					body: .synced(sampleReply(chatId: .main, turn: later, text: "Later reply"))),
			])
		transport.script = [.text("New answer"), .finish(reason: .stop)]
		let host = ImmediateExecutionHost()
		let coach = makeCoach(transport: transport, store: store, clock: clock, host: host)
		try await coach.retry(retried, in: .main)
		_ = try #require(await coach.settledState(of: retried, in: .main))
		_ = try #require(await host.ended(0))
		let jobs = try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending]))).records
			.compactMap { record -> FlushPendingBody? in
				guard case .deviceLocal(.flushPending(let body)) = record.body else { return nil }
				return body
			}
		#expect(
			jobs.filter { $0.trigger == .staleReset }.map(\.messageUlids) == [
				[earlierQuestion, earlierReply]
			])
		#expect(
			await coach.transcript(.main) == [
				"Retried question", "New answer", "Later question", "Later reply",
			])
		let history = try await coach.history()
		#expect(history.first?.turns.map(\.athleteText) == ["Earlier question"])
		let flushed = sent(.memoryFlush, by: transport).flatMap {
			$0.messages.map(\.unstampedContent)
		}
		#expect(!flushed.contains("Later question"))
		#expect(!flushed.contains("Later reply"))
	}
}
