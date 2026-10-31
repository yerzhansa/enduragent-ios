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

	@Test func backgroundTimeFixtureKeepsTheScriptedModelAndSavedMemory() async throws {
		let system = StubBackgroundSystem()
		var configured = launch
		configured.host = try FixtureHostPolicy(argument: "background-time")
		let services = try fixtureServices(
			configured, defaults: defaults, backgroundSystem: system)
		let model = await model(services)
		await model.agreeAndStartChatting()
		#expect(services.fixture?.host == nil)
		model.draft.text = "fixture:memory-until-system-interruption"
		await model.send()
		try await until { system.graces.count == 1 }
		let leases = await services.leases()
		#expect(leases.map(\.id) == system.graces)
		#expect(leases.map(\.kind) == [.gracePeriodOnly])
		let probe = services.coach.recordSyncProbe()
		try await until {
			try await probe.snapshot().counts.contains {
				$0.kind == "memorySection" && $0.count == 1
			}
		}
		try await Task.sleep(for: .seconds(32))
		#expect(model.chat?.turns.last?.state.isSettled == false)
		#expect(system.endedGraces.isEmpty)
		let graceEnds = try #require(system.graceExpirations.first)
		graceEnds()
		try await until { !system.endedGraces.isEmpty }
		let settled = try await settledTurn(model)
		guard case .interrupted(let interrupted) = settled.state else {
			Issue.record("Expected background time to end the reply, got \(settled.state)")
			return
		}
		#expect(interrupted.cause == .graceEnded)
		#expect(interrupted.saved.memorySections == 1)
		#expect(await services.leases().first?.ending == .interrupted(.graceEnded))
		#expect(
			try await probe.snapshot().counts.contains {
				$0.kind == "memorySection" && $0.count == 1
			})
		#expect(services.fixtureTransport?.requestCount == 2)
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
