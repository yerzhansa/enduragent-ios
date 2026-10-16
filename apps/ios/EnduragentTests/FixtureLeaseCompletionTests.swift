import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: LeaseCompletionScenario.allCases)
	func backgroundTimeEndsAfterSettlement(_ scenario: LeaseCompletionScenario) async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let observed = SettlementObservingHost(inner: host)
		let transport = FakeModelTransport(respond: ScriptedReply.sequence(scenario.events))
		let coach = try await leaseCoach(host: observed, transport: transport)
		observed.coach = coach
		system.onEndGrace = { observed.events.append("released") }
		let turn = try #require(
			try await coach.send(Draft(id: DraftID(), text: "Thursday?"), to: .main).turn)
		try await until { system.graces.count == 1 }
		let graceEnds = try #require(system.graceExpirations.first)
		switch scenario {
		case .stop, .expiry:
			try await until {
				if case .processing? = await self.leaseState(coach, turn: turn) {
					true
				} else {
					false
				}
			}
			if scenario == .stop {
				await coach.stop(.main)
			} else {
				graceEnds()
				graceEnds()
			}
		case .success, .failure:
			break
		}
		try await until { host.leases.first?.ending != nil }
		try await until { !system.endedGraces.isEmpty }
		#expect(observed.events == ["settled", "released"])
		#expect(observed.settledCounts == [1])
		let state = try #require(await leaseState(coach, turn: turn))
		switch scenario {
		case .stop, .expiry:
			guard case .interrupted(let interrupted) = state else {
				Issue.record("Expected interruption, got \(state)")
				return
			}
			let cause: InterruptionCause = scenario == .stop ? .athleteStopped : .graceEnded
			#expect(interrupted.cause == cause)
			#expect(interrupted.notice.actions == [.tryAgain(turn)])
			#expect(host.leases.first?.ending == .interrupted(cause))
		case .success:
			#expect(replyText(state) == "Still on.")
			#expect(host.leases.first?.ending == .finished)
		case .failure:
			guard case .failed(let failed) = state else {
				Issue.record("Expected failure, got \(state)")
				return
			}
			#expect(failed.notice?.actions == [.tryAgain(turn)])
			#expect(host.leases.first?.ending == .failed)
		}
		transport.respond = { _ in ScriptedReply([.hang]) }
		system.onBeginGrace = { #expect(host.leases.first?.ending != nil) }
		let next = try #require(
			try await coach.send(Draft(id: DraftID(), text: "Friday?"), to: .main).turn)
		try await until { system.graces.count == 2 }
		graceEnds()
		await coach.stop(.main)
		try await until { host.leases.last?.ending != nil }
		#expect(await leaseState(coach, turn: next)?.isSettled == true)
		#expect(host.leases.last?.ending == .interrupted(.athleteStopped))
		#expect(system.endedGraces.count == 2)
	}

	@Test func expiryWaitsForSettlementAndIgnoresDuplicateCallbacks() async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let settlement = ExpirySettlementGate()
		let lease = await host.beginLease(athleteRequest) { _ in
			await settlement.wait()
		}
		let graceEnds = try #require(system.graceExpirations.first)
		graceEnds()
		try await until { await settlement.started }
		graceEnds()
		await lease.end(.finished)
		#expect(system.endedGraces.isEmpty)
		#expect(host.leases.first?.ending == nil)
		await settlement.release()
		try await until { !system.endedGraces.isEmpty }
		await lease.end(.interrupted(.athleteStopped))
		#expect(system.endedGraces.count == 1)
		#expect(host.leases.first?.ending == .interrupted(.graceEnded))
	}
}

enum LeaseCompletionScenario: CaseIterable, Sendable {
	case stop
	case success
	case failure
	case expiry

	var events: [ScriptedEvent] {
		switch self {
		case .stop, .expiry: [.text("Still"), .hang]
		case .success: [.text("Still on."), .finish(reason: .stop)]
		case .failure: [.fail(.http(status: 400))]
		}
	}
}

extension SendOutcome {
	fileprivate var turn: TurnID? {
		guard case .accepted(let turn) = self else { return nil }
		return turn
	}
}
