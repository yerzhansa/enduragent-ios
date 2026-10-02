import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: LeaseCompletionScenario.allCases, [false, true])
	func continuedTaskCompletionFollowsSettlement(
		_ scenario: LeaseCompletionScenario, lateAttachment: Bool
	) async throws {
		let system = StubBackgroundSystem()
		system.isActive = false
		let host = leaseHost(system)
		let observed = SettlementObservingHost(inner: host)
		let transport = FakeModelTransport(respond: ScriptedReply.sequence(scenario.events))
		let coach = try await leaseCoach(host: observed, transport: transport)
		observed.coach = coach
		let turn = try #require(
			try await coach.send(Draft(id: DraftID(), text: "Thursday?"), to: .main).turn)
		try await waitForLease { system.submitted.count == 1 }
		let request = try #require(system.submitted.first)
		let launchTask = try #require(system.launchHandlers[request.identifier])
		let task = FakeContinuedTask()
		task.onCompletion = { observed.events.append("completed") }
		if !lateAttachment { launchTask(task) }
		let expiration = task.expirationHandler
		switch scenario {
		case .stop, .expiry, .cancel:
			try await waitForLease {
				if case .processing? = await self.leaseState(coach, turn: turn) {
					true
				} else {
					false
				}
			}
			if scenario == .stop {
				await coach.stop(.main)
			} else {
				if lateAttachment { launchTask(task) }
				let interrupt = try #require(task.expirationHandler)
				interrupt()
				interrupt()
			}
		case .success, .failure:
			break
		}
		try await waitForLease { host.leases.first?.ending != nil }
		if lateAttachment { launchTask(task) }
		try await waitForLease { !task.completed.isEmpty }
		if lateAttachment && (scenario == .stop || scenario == .success || scenario == .failure) {
			#expect(system.canceled == [request.identifier])
		} else {
			#expect(system.canceled.isEmpty)
		}
		#expect(observed.events == ["settled", "completed"])
		#expect(task.completed == [scenario.success])
		#expect(observed.settledCounts == [1])
		let state = try #require(await leaseState(coach, turn: turn))
		switch scenario {
		case .stop, .expiry, .cancel:
			guard case .interrupted(let interrupted) = state else {
				Issue.record("Expected interruption, got \(state)")
				return
			}
			let cause: InterruptionCause = scenario == .stop ? .athleteStopped : .systemExpired
			#expect(interrupted.cause == cause)
			#expect(host.leases.first?.ending == .interrupted(cause))
			#expect(system.posted.isEmpty)
		case .success:
			#expect(replyText(state) == "Still on.")
			try await waitForLease { system.posted.count == 1 }
			#expect(system.posted.first?.content.body == "Still on.")
		case .failure:
			guard case .failed(let failed) = state else {
				Issue.record("Expected failure, got \(state)")
				return
			}
			#expect(failed.notice.action == .tryAgain(turn))
			#expect(host.leases.first?.ending == .failed(nil))
			#expect(system.posted.isEmpty)
		}
		transport.respond = { _ in ScriptedReply([.hang]) }
		system.onSubmit = { #expect(host.leases.first?.ending != nil) }
		let next = try #require(
			try await coach.send(Draft(id: DraftID(), text: "Friday?"), to: .main).turn)
		try await waitForLease { system.submitted.count == 2 }
		#expect(system.submitted[1].identifier != request.identifier)
		expiration?()
		await coach.stop(.main)
		try await waitForLease { host.leases.last?.ending != nil }
		#expect(await leaseState(coach, turn: next)?.isSettled == true)
		#expect(task.completed == [scenario.success])
	}

	@Test func nextTaskWaitsForPreviousLeaseClosure() async throws {
		let system = StubBackgroundSystem()
		system.isActive = false
		let closure = ExpirySettlementGate()
		system.postGate = closure
		let host = leaseHost(system)
		let transport = FakeModelTransport(
			respond: ScriptedReply.sequence([.text("Still on."), .finish(reason: .stop)]))
		let coach = try await leaseCoach(host: host, transport: transport)
		_ = try await coach.send(Draft(id: DraftID(), text: "Thursday?"), to: .main)
		try await waitForLease { await closure.started }
		transport.respond = { _ in ScriptedReply([.hang]) }
		system.onSubmit = { #expect(system.posted.count == 1) }
		_ = try await coach.send(Draft(id: DraftID(), text: "Friday?"), to: .main)
		await coach.lifecycle(.enteredBackground)
		try await Task.sleep(for: .milliseconds(200))
		#expect(system.submitted.count == 1)
		await closure.release()
		try await waitForLease { system.submitted.count == 2 }
		await coach.stop(.main)
		try await waitForLease { host.leases.last?.ending != nil }
		#expect(system.posted.count == 1)
	}

	@Test(arguments: [false, true])
	func continuedTaskTitlesFollowMidReplyLanguageChanges(lateAttachment: Bool) async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let transport = FakeModelTransport(respond: { _ in ScriptedReply([.hang]) })
		let coach = try await leaseCoach(host: host, transport: transport)
		let turn = try #require(
			try await coach.send(Draft(id: DraftID(), text: "Thursday?"), to: .main).turn)
		try await waitForLease { system.submitted.count == 1 }
		let request = try #require(system.submitted.first)
		let launchTask = try #require(system.launchHandlers[request.identifier])
		let task = FakeContinuedTask()
		if !lateAttachment { launchTask(task) }
		try await waitForLease {
			if case .processing? = await self.leaseState(coach, turn: turn) { true } else { false }
		}
		try await coach.setLanguage(.fixed(.es))

		if lateAttachment { launchTask(task) }
		#expect(task.titles.last == "El entrenador está trabajando…")
		try await coach.setLanguage(.automatic)
		try await waitForLease { task.titles.last == "Coach is working…" }
		await coach.stop(.main)
		try await waitForLease { !task.completed.isEmpty }
		let closedTitles = task.titles
		try await coach.setLanguage(.fixed(.de))
		#expect(task.titles == closedTitles)
		#expect(system.submitted.count == 1)
	}

	@Test func expiryWaitsForSettlementAndIgnoresDuplicateCallbacks() async throws {
		let system = StubBackgroundSystem()
		system.isActive = false
		let host = leaseHost(system)
		let settlement = ExpirySettlementGate()
		let lease = await host.beginLease(athleteRequest) { _ in
			await settlement.wait()
		}
		let request = try #require(system.submitted.first)
		let task = FakeContinuedTask()
		let launchTask = try #require(system.launchHandlers[request.identifier])
		launchTask(task)
		let interrupt = try #require(task.expirationHandler)
		interrupt()
		try await waitForLease { await settlement.started }
		interrupt()
		await lease.end(.finished(nil))
		#expect(task.completed.isEmpty)
		#expect(host.leases.first?.ending == nil)
		await settlement.release()
		try await waitForLease { !task.completed.isEmpty }
		await lease.end(.interrupted(.athleteStopped))
		#expect(task.completed == [false])
		#expect(host.leases.first?.ending == .interrupted(.systemExpired))
		#expect(system.posted.isEmpty)
	}

	@Test func continuedProcessingFixtureKeepsTheScriptedModelAndSavedMemory() async throws {
		let system = StubBackgroundSystem()
		system.isActive = false
		var configured = launch
		configured.host = try FixtureHostPolicy(argument: "continued-processing")
		let services = try fixtureServices(
			configured, defaults: defaults, backgroundSystem: system)
		let model = model(services)
		await model.agreeAndStartChatting()
		#expect(services.fixture?.host == nil)
		model.draft.text = "fixture:memory-until-system-interruption"
		await model.send()
		try await waitForLease { system.submitted.count == 1 }
		let request = try #require(system.submitted.first)
		let task = FakeContinuedTask()
		let launchTask = try #require(system.launchHandlers[request.identifier])
		launchTask(task)
		let probe = services.coach.recordSyncProbe()
		try await waitForLease {
			try await probe.snapshot().counts.contains {
				$0.kind == "memorySection" && $0.count == 1
			}
		}
		try await Task.sleep(for: .seconds(32))
		#expect(model.chat?.turns.last?.state.isSettled == false)
		#expect(task.completed.isEmpty)
		let interrupt = try #require(task.expirationHandler)
		interrupt()
		try await waitForLease { !task.completed.isEmpty }
		#expect(task.completed == [false])
		#expect(await services.leases().first?.ending == .interrupted(.systemExpired))
		#expect(
			try await probe.snapshot().counts.contains {
				$0.kind == "memorySection" && $0.count == 1
			})
		#expect(services.fixtureTransport?.requestCount == 2)
		#expect(FixtureBlockingURLProtocol.requestCount == 0)
		#expect(system.posted.isEmpty)
	}
}

enum LeaseCompletionScenario: CaseIterable, Sendable {
	case stop
	case success
	case failure
	case expiry
	case cancel

	var events: [ScriptedEvent] {
		switch self {
		case .stop, .expiry, .cancel: [.text("Still"), .hang]
		case .success: [.text("Still on."), .finish(reason: .stop)]
		case .failure: [.fail(.http(status: 401))]
		}
	}

	var success: Bool {
		switch self {
		case .stop, .success, .failure: true
		case .expiry, .cancel: false
		}
	}
}

extension SendOutcome {
	fileprivate var turn: TurnID? {
		guard case .accepted(let turn) = self else { return nil }
		return turn
	}
}
