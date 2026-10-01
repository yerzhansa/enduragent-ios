import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct CoachLifetimeTests {
	@Test(arguments: [false, true])
	func releasingTheOwnerReleasesTheCoachAndRecordLog(terminating: Bool) async throws {
		weak var releasedCoach: Coach?
		weak var releasedLog: FaultInjectingRecordLog?
		do {
			let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
			let transport = FakeModelTransport()
			transport.respond = ScriptedReply.sequence(
				[.text("Lifetime answer"), .finish(reason: .stop)], otherwise: transport.respond)
			let coach = await makeCoach(transport: transport, store: log)
			releasedCoach = coach
			releasedLog = log
			#expect(
				replyText(try await coach.sendAndSettle("Lifetime question")) == "Lifetime answer")
			if terminating { await coach.lifecycle(.willTerminate) }
		}
		let deadline = ContinuousClock.now + .seconds(5)
		while releasedCoach != nil || releasedLog != nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(releasedCoach == nil, "Coach was not released within five seconds")
		#expect(releasedLog == nil, "Record log store owner was not released within five seconds")
	}
}
