import Testing

@testable import EnduragentCoach

@Suite struct MailboxQueueTests {
	@Test func duplicateTurnKeepsItsOriginalOrigin() {
		let queue = MailboxQueue()
		let turn = TurnID(ulid: fixedUlid(1))
		#expect(queue.add(turn, origin: .send))
		#expect(!queue.add(turn, origin: .retry))
		#expect(queue.waiting == [.turn(turn, origin: .send)])
	}

	@Test func distinctMaintenanceWorkRemainsQueued() {
		let queue = MailboxQueue()
		let first = ResetID(ulid: fixedUlid(1))
		let second = ResetID(ulid: fixedUlid(2))
		#expect(queue.add(first))
		#expect(queue.add(second))
		#expect(!queue.add(first))
		#expect(queue.waiting == [.reset(first), .reset(second)])
	}
}
