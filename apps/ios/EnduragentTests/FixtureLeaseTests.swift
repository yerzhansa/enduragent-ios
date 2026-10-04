import BackgroundTasks
import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing
import UIKit
import UserNotifications

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func continuedProcessingHostFallsBackToGraceWhenSubmitThrows() async throws {
		let system = StubBackgroundSystem()
		system.submitFailure = BGTaskScheduler.Error(.immediateRunIneligible)
		let host = leaseHost(system)
		let expiries = ExpiryLog()
		let lease = await host.beginLease(athleteRequest) { cause in await expiries.add(cause) }
		#expect(lease.kind == .gracePeriodOnly)
		let request = try #require(system.submitted.first)
		#expect(request.identifier.hasPrefix("icu.enduragent.app.coach."))
		#expect(request.title == "Coach is working…")
		#expect(request.strategy == .fail)
		#expect(system.graces == [request.identifier])
		#expect(host.leases.map(\.kind) == [.gracePeriodOnly])
		#expect(host.leases.first?.notes.count == 1)
		let graceEnds = try #require(system.graceExpirations.first)
		graceEnds()
		try await waitForLease { host.leases.first?.ending != nil }
		#expect(await expiries.causes == [.graceEnded])
		#expect(host.leases.first?.expiry == .graceEnded)
		#expect(host.leases.first?.ending == .interrupted(.graceEnded))
		#expect(system.endedGraces == [UIBackgroundTaskIdentifier(rawValue: 1)])
	}

	@Test func continuedProcessingHostMirrorsProgressAndExpiresTheTask() async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let expiries = ExpiryLog()
		let lease = await host.beginLease(athleteRequest) { cause in await expiries.add(cause) }
		#expect(lease.kind == .continuedProcessing)
		#expect(system.graces.isEmpty)
		let request = try #require(system.submitted.first)
		let task = FakeContinuedTask()
		let launch = try #require(system.launchHandlers[request.identifier])
		launch(task)
		await lease.report(LeaseProgress(settledTurns: 1, totalTurns: 2, step: 3, stepLimit: 10))
		#expect(task.progress.totalUnitCount == 20)
		#expect(task.progress.completedUnitCount == 13)
		let expire = try #require(task.expirationHandler)
		expire()
		try await waitForLease { !task.completed.isEmpty }
		#expect(task.completed == [false])
		#expect(await expiries.causes == [.systemExpired])
		#expect(host.leases.first?.expiry == .systemExpired)
		await lease.end(.finished(nil))
		#expect(task.completed == [false])
		#expect(host.leases.first?.ending == .interrupted(.systemExpired))
	}

	@Test func aRecoveryLeaseUsesTheGracePeriodOnly() async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let recovery = LeaseRequest(
			chat: .main, initiatedBy: .recovery, title: Catalog.chatNoticeWorking,
			language: .en)
		let lease = await host.beginLease(recovery) { _ in }
		#expect(lease.kind == .gracePeriodOnly)
		#expect(system.submitted.isEmpty)
		#expect(system.graces.count == 1)
		await lease.end(.finished(nil))
		#expect(system.endedGraces.count == 1)
		#expect(system.quietRequests == 0)
	}

	@Test func theHostKeepsOnlyTheNewestLeases() async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let recovery = LeaseRequest(
			chat: .main, initiatedBy: .recovery, title: Catalog.chatNoticeWorking,
			language: .en)
		for _ in 0...ContinuedProcessingHost.keptLeases {
			await host.beginLease(recovery) { _ in }.end(.finished(nil))
		}
		#expect(host.leases.count == ContinuedProcessingHost.keptLeases)
		#expect(host.leases.first?.id == system.graces[1])
		#expect(host.leases.last?.id == system.graces.last)
	}

	@Test func aReplyFinishedAwayPostsOneNotification() async throws {
		let system = StubBackgroundSystem()
		system.isActive = false
		let coach = try await leaseCoach(host: leaseHost(system))
		_ = try await reply(to: "Is Thursday on?", from: coach)
		try await waitForLease { !system.posted.isEmpty }
		#expect(system.posted.count == 1)
		#expect(system.posted.first?.content.title == "Coach")
		#expect(system.posted.first?.content.body == "Still on.")
		#expect(system.quietRequests == 1)
	}

	@Test func backgroundTitlesFollowTheChosenLanguage() async throws {
		let system = StubBackgroundSystem()
		system.isActive = false
		let coach = try await leaseCoach(host: leaseHost(system))
		try await coach.setLanguage(.fixed(.es))
		_ = try await reply(to: "Is Thursday on?", from: coach)
		try await waitForLease { !system.posted.isEmpty }
		#expect(system.submitted.map(\.title) == ["El entrenador está trabajando…"])
		#expect(system.posted.map(\.content.title) == ["Entrenador"])
	}

	@Test func aReplyFinishedInTheAppPostsNoNotification() async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let coach = try await leaseCoach(host: host)
		_ = try await reply(to: "Is Thursday on?", from: coach)
		try await waitForLease { host.leases.first?.ending != nil }
		#expect(system.posted.isEmpty)
	}

	@Test func fixtureHostArgumentParsesExpireAfter() throws {
		#expect(try FixtureHostPolicy(argument: "expire-after 3") == .expireAfter(.seconds(3)))
		#expect(throws: FixtureLaunchError.self) { try FixtureHostPolicy(argument: "expire 3") }
		#expect(throws: FixtureLaunchError.self) {
			try FixtureHostPolicy(argument: "expire-after 0")
		}
	}

	@Test func fixtureExpireInterruptsTheRunningTurnAsSystemExpired() async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:memory-then-hang"
		await model.send()
		let running = try await leaseTurn(in: model) { state in
			if case .processing = state { true } else { false }
		}
		let records = services.coach.recordSyncProbe()
		try await waitForLease {
			try await records.snapshot().counts.contains {
				$0.kind == "memorySection" && $0.count > 0
			}
		}
		await services.fixture?.host?.expire(.systemExpired)
		try await waitForLease {
			guard
				case .interrupted? = model.chat?.turns.first(where: { $0.id == running.id })?.state
			else { return false }
			return true
		}
		let state = try #require(model.chat?.turns.first { $0.id == running.id }?.state)
		guard case .interrupted(let interrupted) = state else {
			Issue.record("expected interrupted, got \(state)")
			return
		}
		#expect(interrupted.cause == .systemExpired)
		#expect(interrupted.notice.key == Catalog.chatTurnInterruptedSomeSaved)
		#expect(interrupted.notice.actions.isEmpty)
		#expect(await services.leases().first?.expiry == .systemExpired)
		await model.stop()
	}

	var athleteRequest: LeaseRequest {
		LeaseRequest(
			chat: .main, initiatedBy: .athlete, title: Catalog.chatNoticeWorking,
			language: .en)
	}

	func leaseHost(_ system: StubBackgroundSystem) -> ContinuedProcessingHost {
		ContinuedProcessingHost(bundleIdentifier: "icu.enduragent.app", system: system)
	}

	func leaseCoach(
		host: any ExecutionHost, transport: FakeModelTransport? = nil
	) async throws -> Coach {
		let transport =
			transport
			?? FakeModelTransport(
				respond: ScriptedReply.sequence([.text("Still on."), .finish(reason: .stop)]))
		let secrets = try ICloudKeychainStore.fixture(directory: launch.directory).store
		try secrets.storeCreditsAccount(
			CreditsAccount(
				appAccountToken: UUID(), key: "sk-or-test-lease"))
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let clock = FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana")
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: .inMemory(deviceId: DeviceID()),
				secrets: secrets,
				models: .scripted(transport, catalog: .bundled),
				training: .fake { _, _ in intervals },
				credits: .fake(FakeCreditsClient()),
				host: host,
				clock: clock
			),
			builtInModel: AppServices.builtInModel,
			displayLocale: testLocaleResolver(),
			coalescing: CoalescingPolicy(window: .milliseconds(20))
		)
		let services = AppServices(
			coach: coach, deviceCheck: FakeDeviceCheckTokenProvider(), clock: clock,
			leases: { [] }, packPrices: { _ in [:] })
		await model(services).agreeAndStartChatting()
		return coach
	}

	private func reply(to text: String, from coach: Coach) async throws -> String {
		guard
			case .accepted(let turn) = try await coach.send(
				Draft(id: DraftID(), text: text), to: .main)
		else {
			Issue.record("the message was not accepted")
			return ""
		}
		try await waitForLease { await self.leaseState(coach, turn: turn)?.isSettled == true }
		let state = try #require(await leaseState(coach, turn: turn))
		return try #require(replyText(state), "Expected a completed reply, got \(state)")
	}

	func leaseState(_ coach: Coach, turn: TurnID) async -> TurnState? {
		var iterator = await coach.observe(.main).makeAsyncIterator()
		return await iterator.next()?.turns.first { $0.id == turn }?.state
	}

	private func leaseTurn(in model: ShellModel, where matches: (TurnState) -> Bool)
		async throws -> TurnView
	{
		try await waitForLease { model.chat?.turns.last.map { matches($0.state) } ?? false }
		return try #require(model.chat?.turns.last)
	}

	func waitForLease(
		within limit: TestWaitLimit = .hangGuard, _ condition: () async throws -> Bool
	) async throws {
		let deadline = ContinuousClock.now + limit.duration
		while try await !condition() {
			guard ContinuousClock.now < deadline else {
				Issue.record("the condition never held within \(limit)")
				return
			}
			try await Task.sleep(for: .milliseconds(20))
		}
	}
}

actor ExpiryLog {
	private(set) var causes: [ExpiryCause] = []

	func add(_ cause: ExpiryCause) {
		causes.append(cause)
	}
}

@MainActor
final class FakeContinuedTask: ContinuedTask {
	let progress = Progress()
	var expirationHandler: (() -> Void)?
	private(set) var completed: [Bool] = []

	private(set) var titles: [String] = []
	var onCompletion: (() -> Void)?

	func updateTitle(_ title: String, subtitle: String) {
		titles.append(title)
	}

	func setTaskCompleted(success: Bool) {
		completed.append(success)
		onCompletion?()
	}
}

@MainActor
final class StubBackgroundSystem: BackgroundSystem {
	var isActive = true
	var submitFailure: (any Error)?
	var onSubmit: (() -> Void)?
	var postGate: ExpirySettlementGate?
	private(set) var canceled: [String] = []
	private(set) var launchHandlers: [String: (any ContinuedTask) -> Void] = [:]
	private(set) var submitted: [BGContinuedProcessingTaskRequest] = []
	private(set) var graces: [String] = []
	private(set) var graceExpirations: [() -> Void] = []
	private(set) var endedGraces: [UIBackgroundTaskIdentifier] = []
	private(set) var posted: [UNNotificationRequest] = []
	private(set) var quietRequests = 0

	func register(_ identifier: String, launchHandler: @escaping (any ContinuedTask) -> Void)
		-> Bool
	{
		launchHandlers[identifier] = launchHandler
		return true
	}

	func submit(_ request: BGContinuedProcessingTaskRequest) throws {
		onSubmit?()
		submitted.append(request)
		if let submitFailure {
			throw submitFailure
		}
	}

	func cancel(_ identifier: String) {
		canceled.append(identifier)
	}

	func beginGrace(named name: String, expiration: @escaping () -> Void)
		-> UIBackgroundTaskIdentifier
	{
		graces.append(name)
		graceExpirations.append(expiration)
		return UIBackgroundTaskIdentifier(rawValue: graces.count)
	}

	func endGrace(_ identifier: UIBackgroundTaskIdentifier) {
		endedGraces.append(identifier)
	}

	func allowQuietNotifications() async throws {
		quietRequests += 1
	}

	func post(_ request: UNNotificationRequest) async throws {
		await postGate?.wait()
		posted.append(request)
	}
}
