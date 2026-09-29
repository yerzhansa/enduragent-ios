import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct LongGapTests {
	let transport = FakeModelTransport()
	let store = InMemoryRecordLog()

	@Test(arguments: [false, true])
	func aThirteenHourGapKeepsOneConversation(relaunch: Bool) async throws {
		let clock = FixedClock(now: "1998-06-15T20:00:00+02:00", timeZone: "Europe/Amsterdam")
		transport.script = [
			.text("Good, keep them at 105%."), .finish(reason: .stop),
			.text("Expected after yesterday's intervals."), .finish(reason: .stop),
		]
		let evening = makeCoach(transport: transport, store: store, clock: clock)
		_ = try await evening.sendAndSettle("I'm doing intervals today.")
		clock.advance(by: 13 * 3600)
		let morning =
			relaunch ? makeCoach(transport: transport, store: store, clock: clock) : evening
		_ = try await morning.sendAndSettle("My legs are sore.")
		#expect(
			await morning.transcript(.main) == [
				"I'm doing intervals today.", "Good, keep them at 105%.", "My legs are sore.",
				"Expected after yesterday's intervals.",
			])
		#expect(await morning.currentSnapshot(.main)?.opening == .continuing)
		#expect(try await morning.history().isEmpty)
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.windowStart]))).records.isEmpty)
		#expect(
			try await store.fetch(RecordQuery(scope: .deviceLocal([.flushPending]))).records.isEmpty
		)
		let chat = try #require(sent(.chatAttempt, by: transport).last)
		#expect(chat.messages.filter { $0.role == .system }.count == 1)
		#expect(
			chat.messages.dropFirst().map(\.content) == [
				"[Mon 1998-06-15 20:00 Europe/Amsterdam] I'm doing intervals today.",
				"Good, keep them at 105%.",
				"My legs are sore.\nCurrent time: Tuesday, June 16th, 1998 - 09:00 (Europe/Amsterdam) / 1998-06-16 07:00 UTC",
			])
	}
}
