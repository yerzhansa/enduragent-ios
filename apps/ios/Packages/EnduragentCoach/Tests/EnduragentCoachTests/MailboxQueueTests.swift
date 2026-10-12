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
		let first = ReservedReset(
			id: ResetID(ulid: fixedUlid(1)),
			boundary: HybridLogicalClock(
				wallMs: 1, logical: 0, deviceId: DeviceID(rawValue: "phone-a")))
		let second = ReservedReset(
			id: ResetID(ulid: fixedUlid(2)),
			boundary: HybridLogicalClock(
				wallMs: 2, logical: 0, deviceId: DeviceID(rawValue: "phone-a")))
		#expect(queue.add(first))
		#expect(queue.add(second))
		#expect(!queue.add(first))
		#expect(queue.waiting == [.reset(first), .reset(second)])
	}
}
