import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct CoachLifetimeTests {
	enum PendingTurn: CaseIterable {
		case collecting
		case hanging
		case queuedBehindHang
	}

	@Test(arguments: PendingTurn.allCases)
	func terminationReleasesTheOwnerOfUnfinishedTurns(pending: PendingTurn) async throws {
		weak var releasedCoach: Coach?
		weak var releasedLog: FaultInjectingRecordLog?
		let coalescingClock = HeldClock()
		let window = Duration.seconds(60)
		do {
			let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
			let transport = FakeModelTransport()
			transport.respond = ScriptedReply.sequence([.hang], otherwise: transport.respond)
			let coach = await makeCoach(
				transport: transport, store: log,
				coalescing: CoalescingPolicy(window: window), coalescingClock: coalescingClock)
			releasedCoach = coach
			releasedLog = log
			let first = try #require(
				try await coach.send(draft("Pending turn"), to: .main).acceptedTurn)
			try await waitUntil { coalescingClock.held.contains(window) }
			try #require(coalescingClock.held.contains(window))
			if pending != .collecting {
				coalescingClock.release(window)
				_ = try #require(
					try await coach.waitForState(of: first) {
						if case .processing? = $0 { true } else { false }
					})
				try await waitUntil { transport.requestCount == 1 }
				try #require(transport.requestCount == 1)
				if pending == .queuedBehindHang {
					_ = try await coach.send(draft("Queued turn"), to: .main)
					try await waitUntil { coalescingClock.held.contains(window) }
					try #require(coalescingClock.held.contains(window))
				}
			}
			await coach.lifecycle(.willTerminate)
			#expect(transport.requestCount == (pending == .collecting ? 0 : 1))
		}
		let deadline = ContinuousClock.now + .seconds(5)
		while releasedCoach != nil || releasedLog != nil, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(releasedCoach == nil, "Coach was not released within five seconds")
		#expect(releasedLog == nil, "Record log store owner was not released within five seconds")
		#expect(coalescingClock.held.isEmpty, "Termination left a coalescing task asleep")
		coalescingClock.release(window)
	}

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
