import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing
import UIKit

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func anAthleteLeaseTakesBackgroundTimeUntilIOSEndsIt() async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let expiries = ExpiryLog()
		let lease = await host.beginLease(athleteRequest) { cause in await expiries.add(cause) }
		#expect(lease.kind == .gracePeriodOnly)
		let identifier = try #require(system.graces.first)
		#expect(identifier.hasPrefix("icu.enduragent.app.coach."))
		#expect(host.leases.map(\.id) == [identifier])
		let graceEnds = try #require(system.graceExpirations.first)
		graceEnds()
		try await until { host.leases.first?.ending != nil }
		#expect(await expiries.causes == [.graceEnded])
		#expect(host.leases.first?.expiry == .graceEnded)
		#expect(host.leases.first?.ending == .interrupted(.graceEnded))
		#expect(system.endedGraces == [UIBackgroundTaskIdentifier(rawValue: 1)])
	}

	@Test func aFinishedLeaseGivesBackItsBackgroundTime() async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let lease = await host.beginLease(athleteRequest) { _ in }
		await lease.end(.finished)
		await lease.end(.failed)
		#expect(system.endedGraces == [UIBackgroundTaskIdentifier(rawValue: 1)])
		#expect(host.leases.first?.ending == .finished)
	}

	@Test func theHostKeepsOnlyTheNewestLeases() async throws {
		let system = StubBackgroundSystem()
		let host = leaseHost(system)
		let recovery = LeaseRequest(chat: .main, initiatedBy: .recovery)
		for _ in 0...BackgroundTimeHost.keptLeases {
			await host.beginLease(recovery) { _ in }.end(.finished)
		}
		#expect(host.leases.count == BackgroundTimeHost.keptLeases)
		#expect(host.leases.first?.id == system.graces[1])
		#expect(host.leases.last?.id == system.graces.last)
	}

	@Test func fixtureHostArgumentParsesBackgroundTimeAndExpireAfter() throws {
		#expect(try FixtureHostPolicy(argument: "background-time") == .backgroundTime)
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
		try await until {
			try await records.snapshot().counts.contains {
				$0.kind == "memorySection" && $0.count > 0
			}
		}
		await services.fixture?.host?.expire(.systemExpired)
		try await until {
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
		LeaseRequest(chat: .main, initiatedBy: .athlete)
	}

	func leaseHost(_ system: StubBackgroundSystem) -> BackgroundTimeHost {
		BackgroundTimeHost(bundleIdentifier: "icu.enduragent.app", system: system)
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

	func leaseState(_ coach: Coach, turn: TurnID) async -> TurnState? {
		var iterator = await coach.observe(.main).makeAsyncIterator()
		return await iterator.next()?.turns.first { $0.id == turn }?.state
	}

	private func leaseTurn(in model: ShellModel, where matches: (TurnState) -> Bool)
		async throws -> TurnView
	{
		try await until { model.chat?.turns.last.map { matches($0.state) } ?? false }
		return try #require(model.chat?.turns.last)
	}
}

actor ExpiryLog {
	private(set) var causes: [ExpiryCause] = []

	func add(_ cause: ExpiryCause) {
		causes.append(cause)
	}
}

@MainActor
final class StubBackgroundSystem: BackgroundSystem {
	var onBeginGrace: (() -> Void)?
	var onEndGrace: (() -> Void)?
	private(set) var graces: [String] = []
	private(set) var graceExpirations: [() -> Void] = []
	private(set) var endedGraces: [UIBackgroundTaskIdentifier] = []

	func beginGrace(named name: String, expiration: @escaping () -> Void)
		-> UIBackgroundTaskIdentifier
	{
		onBeginGrace?()
		graces.append(name)
		graceExpirations.append(expiration)
		return UIBackgroundTaskIdentifier(rawValue: graces.count)
	}

	func endGrace(_ identifier: UIBackgroundTaskIdentifier) {
		endedGraces.append(identifier)
		onEndGrace?()
	}
}
