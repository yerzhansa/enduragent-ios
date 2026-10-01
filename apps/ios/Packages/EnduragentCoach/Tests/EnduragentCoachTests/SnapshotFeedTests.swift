import Testing

@testable import EnduragentCoach

struct SnapshotFeedTests {
	@Test func slowSubscriberSeesNewestOnly() async throws {
		let transport = FakeModelTransport()
		transport.script = [.text("Thursday is on."), .finish(reason: .stop)]
		let coach = await makeCoach(transport: transport, store: InMemoryRecordLog())
		let first = try #require(await coach.currentSnapshot(.main))
		let feed = SnapshotFeed()
		var slow = feed.subscribe(from: first).makeAsyncIterator()
		var fast = feed.subscribe(from: first).makeAsyncIterator()
		#expect(await fast.next() == first)
		_ = try await coach.sendAndSettle("Thursday?")
		let newest = try #require(await coach.currentSnapshot(.main))
		for _ in 0..<100 {
			feed.publish(first)
		}
		feed.publish(newest)
		#expect(await slow.next() == newest)
		#expect(await fast.next() == newest)
	}
}
