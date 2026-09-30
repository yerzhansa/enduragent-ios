import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension ExecutionLeaseTests {
	@Test func theLeaseBeginsAtSendWhileTheWindowIsStillOpen() async throws {
		transport.respond = ScriptedReply.sequence(
			[.text("Still on."), .finish(reason: .stop)], otherwise: transport.respond)
		let coach = makeCoach(
			transport: transport, store: store, clock: clock,
			coalescing: CoalescingPolicy(window: .seconds(60)), host: host)
		let turn = try #require(try await coach.send(draft("Thursday?"), to: .main).acceptedTurn)
		let deadline = ContinuousClock.now + .seconds(2)
		while host.leases.isEmpty, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(host.leases.map(\.request) == [athleteLease])
		#expect(
			await coach.state(of: turn)
				== .accepted(.collecting(until: clock.now.addingTimeInterval(60))))
		await coach.stop(.main)
	}
}
