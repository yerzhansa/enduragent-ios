import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct DataErasureTests {
	@Test func aConfirmedRunDeletesEverythingAndClearsTheMarker() async throws {
		let rig = try await ErasureRig()
		let coach = rig.launch()

		let run = try await rig.begin(coach)
		#expect(rig.device.erasureRun?.progress == .askingCredits)
		#expect(await coach.continueErasure(run) == .done(.erased))

		try await rig.expectEverythingErased(iCloudPending: false)
		#expect(rig.credits.calls == [.erase])
	}

	@Test(arguments: [
		(CreditsFailure.unauthorized as any Error, ErasureOutcome.creditsUnconfirmed),
		(CreditsFailure.rateLimited, .tryLater),
		(CreditsFailure.unavailable, .tryLater),
		(URLError(.notConnectedToInternet), .notStarted),
	])
	func anUnconfirmedCreditsErasureDeletesNothingAndSaysWhy(
		_ failure: any Error, _ outcome: ErasureOutcome
	) async throws {
		let rig = try await ErasureRig()
		rig.credits.eraseResult = .failure(failure)
		let coach = rig.launch()

		#expect(await coach.continueErasure(try await rig.begin(coach)) == outcome)

		#expect(rig.device.erasure == nil)
		try await rig.expectNothingErased()
		#expect(
			coach.diagnostics.entries.map(\.event).contains(
				.erasureNotStarted(FailureCode(failure))))
	}

	@Test func anAthleteWhoseRecordIsNotConfirmedCanDeleteThisPhoneAndICloudAndIsToldWhatStayed()
		async throws
	{
		let rig = try await ErasureRig()
		rig.credits.eraseResult = .failure(CreditsFailure.unauthorized)
		let first = rig.launch()
		#expect(await first.continueErasure(try await rig.begin(first)) == .creditsUnconfirmed)

		let kept = try await rig.begin(first, .thisPhoneAndICloud)
		try rig.fail(.keychain)
		guard case .notFinished(.keychain, _) = await first.continueErasure(kept) else {
			Issue.record("the stopped run did not report the Keychain step")
			return
		}
		try rig.recover(.keychain)

		let resumed = try #require(rig.device.erasureRun)
		#expect(await rig.launch().continueErasure(resumed) == .done(.kept))
		try await rig.expectEverythingErased(iCloudPending: false)
		#expect(rig.credits.calls == [.erase])
	}

	@Test(arguments: [ErasureStep.iCloud, .deviceRecords, .files, .keychain])
	func aRunStoppedAtAStepResumesAfterRelaunchWithoutAskingCreditsAgain(_ step: ErasureStep)
		async throws
	{
		let rig = try await ErasureRig()
		let first = rig.launch()
		let run = try await rig.begin(first)
		try rig.fail(step)

		let stopped = await first.continueErasure(run)
		let saved = try #require(rig.device.erasureRun)
		#expect(stopped == .notFinished(step, resume: saved))
		#expect(
			first.diagnostics.entries.contains {
				if case .erasureNotFinished(step, _) = $0.event { return true }
				return false
			})

		try rig.recover(step)
		#expect(await rig.launch().continueErasure(saved) == .done(.erased))
		try await rig.expectEverythingErased(iCloudPending: false)
		#expect(rig.credits.calls == [.erase])
	}

	@Test func aRunKilledBeforeCreditsAnsweredAsksCreditsAgainOnResume() async throws {
		let rig = try await ErasureRig()
		_ = try await rig.begin(rig.launch())

		let resumed = try #require(rig.device.erasureRun)
		#expect(await rig.launch().continueErasure(resumed) == .done(.erased))
		try await rig.expectEverythingErased(iCloudPending: false)
		#expect(rig.credits.calls == [.erase])
	}

	@Test func anUnconfirmedExportFinishesOnThisPhoneAndKeepsTheICloudMarker() async throws {
		let rig = try await ErasureRig()
		rig.records.export = .noAccount
		let coach = rig.launch()

		#expect(await coach.continueErasure(try await rig.begin(coach)) == .iCloudLater(.erased))
		try await rig.expectEverythingErased(iCloudPending: true)
	}

	@Test(arguments: [
		(FixtureExport.noAccount, ErasureOutcome.iCloudLater(.erased)),
		(.confirmed, .done(.erased)),
	])
	func aRunResumedAfterTheSyncedDeleteWaitsForAnExportAgain(
		_ export: FixtureExport, _ outcome: ErasureOutcome
	) async throws {
		let rig = try await ErasureRig()
		rig.records.export = .held
		let first = rig.launch()
		let run = try await rig.begin(first)
		let killed = Task { await first.continueErasure(run) }
		try await rig.waitUntilSyncedRowsAreGone()
		killed.cancel()
		_ = await killed.value

		rig.records.export = export
		let resumed = try #require(rig.device.erasureRun)
		#expect(await rig.launch().continueErasure(resumed) == outcome)
		try await rig.expectEverythingErased(iCloudPending: outcome == .iCloudLater(.erased))
	}

	@Test func aRunThatFindsNoSyncedRowsDoesNotReportICloudAsDeleted() async throws {
		let rig = try await ErasureRig()
		_ = try await rig.records.erase(.synced, writtenBefore: nil)
		let coach = rig.launch()

		#expect(await coach.continueErasure(try await rig.begin(coach)) == .iCloudLater(.erased))
		try await rig.expectEverythingErased(iCloudPending: true)
	}

	@Test(arguments: [FixtureExport.noAccount, .confirmed])
	func theNextLaunchDeletesOnlyRowsWrittenBeforeTheErasureAndClearsTheMarkerAfterAnExport(
		_ export: FixtureExport
	) async throws {
		let rig = try await ErasureRig()
		let began = Date(timeIntervalSince1970: 1)
		rig.device.mark(.iCloudPending(began: began))
		let fresh = DeviceID(rawValue: "phone-after-erasure")
		let records = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: fresh))
		records.export = export
		try await records.append(
			[
				storedRecord(
					device: ErasureRig.phone, wall: 500,
					body: .synced(sampleUser(chatId: .main, text: "returning"))),
				storedRecord(
					device: DeviceID(rawValue: "other-phone"), wall: 2_000,
					body: .synced(sampleUser(chatId: .main, text: "written after"))),
				storedRecord(
					device: fresh, wall: 3_000,
					body: .synced(sampleUser(chatId: .main, text: "new"))),
			], locality: .synced)
		let coach = rig.launch(records: records)

		await coach.eraseReturningRows(rig.device)
		await coach.pendingErasure?.value

		let left = try await records.fetch(RecordQuery(scope: .everySynced)).records
		#expect(left.map(messageText) == ["written after", "new"])
		#expect(rig.device.erasure == (export == .confirmed ? nil : .iCloudPending(began: began)))
	}

	@Test func theSweepLeavesANewerRunsMarker() async throws {
		let rig = try await ErasureRig()
		rig.device.mark(.iCloudPending(began: Date(timeIntervalSince1970: 1)))
		rig.records.export = .held
		let coach = rig.launch()
		await coach.eraseReturningRows(rig.device)

		_ = try await rig.begin(coach)
		rig.records.export = .confirmed
		await coach.pendingErasure?.value

		#expect(rig.device.erasureRun?.progress == .askingCredits)
	}

	@Test func aRunningTurnOrAnOpenMessageWindowRefusesToBegin() async throws {
		let rig = try await ErasureRig()
		let gate = FakeModelGate()
		rig.transport.respond = { _ in
			ScriptedReply([.text("Held"), .finish(reason: .stop)], gate: gate)
		}
		let window = HeldClock()
		let coach = await consentingCoach(rig.launch(coalescingClock: window))

		let turn = try #require(try await coach.send(draft("Hold this"), to: .main).acceptedTurn)
		try await window.waitUntilHeld(quickWindow.window)
		#expect(await coach.beginErasure(rig.device, .everything) == .busy)
		window.release(quickWindow.window)
		try await waitForArrival(at: gate)
		#expect(await coach.beginErasure(rig.device, .everything) == .busy)
		#expect(rig.device.erasure == nil)

		await gate.release()
		_ = try #require(await coach.settledState(of: turn, in: .main))
		guard case .begun = try await eventuallyBegins(coach, rig.device) else {
			Issue.record("the erasure did not begin after the turn settled")
			return
		}
		#expect(rig.device.erasureRun?.progress == .askingCredits)
	}

	private func waitForArrival(at gate: FakeModelGate) async throws {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while await gate.arrivals == 0, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		try #require(await gate.arrivals == 1)
	}

	private func eventuallyBegins(_ coach: Coach, _ device: DeviceDefaults) async throws
		-> ErasureStart
	{
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		var start = await coach.beginErasure(device, .everything)
		while start == .busy, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
			start = await coach.beginErasure(device, .everything)
		}
		return start
	}
}

private enum ErasureRigFailure: Error {
	case busy
}

private final class ErasureRig: Sendable {
	static let phone = DeviceID(rawValue: "phone-before-erasure")
	static let now = "1998-06-13T08:00:00+02:00"
	static let began = FixedClock(now: now, timeZone: "Europe/Amsterdam").now
	let directory: URL
	let suite: String
	let device: DeviceDefaults
	let records: FaultInjectingRecordLog
	let backing: FixtureSecretStoreBacking
	let credits: FakeCreditsClient
	let transport: FakeModelTransport
	let support: SupportService

	init() async throws {
		directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		suite = "icu.enduragent.tests.erasure.\(UUID().uuidString)"
		device = DeviceDefaults(suiteName: suite)
		records = FaultInjectingRecordLog(wrapping: InMemoryRecordLog(deviceId: Self.phone))
		backing = FixtureSecretStoreBacking()
		credits = FakeCreditsClient()
		credits.eraseResult = .success(())
		transport = FakeModelTransport { _ in
			ScriptedReply([.text("Week summary"), .finish(reason: .stop)])
		}
		support = SupportService.fixture(directory: directory, app: .fixture)
		try seed()
		try await seedRecords()
	}

	deinit {
		UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
	}

	func launch(records: FaultInjectingRecordLog? = nil, coalescingClock: HeldClock? = nil)
		-> Coach
	{
		var ports = CoachPorts(
			records: RecordStore(log: records ?? self.records),
			secrets: ICloudKeychainStore(backing: backing),
			models: .scripted(
				transport, catalogSource: FakeModelCatalogSource(response: .offline),
				cacheDirectory: directory, catalog: .fixture),
			training: TrainingService { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
			credits: .fake(credits), host: ImmediateExecutionHost(),
			clock: FixedClock(now: Self.now, timeZone: "Europe/Amsterdam"),
			support: support)
		ports.watchdogSleep = HeldClock().sleep
		if let coalescingClock { ports.coalescingSleep = coalescingClock.sleep }
		return Coach(
			sport: .cycling, ports: ports, builtInModel: testModel,
			displayLocale: testDisplayLocale, coalescing: quickWindow)
	}

	private func seed() throws {
		let store = ICloudKeychainStore(backing: backing)
		try store.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		try store.storeIntervalsConnection(testConnection)
		try store.storeOpenRouterAccountKey("synthetic-openrouter-key", at: .legacy)
		try support.journal.append(Data("{}\n".utf8))
		try support.keptNotes.save(
			KeptNote(note: .first(try FeedbackText(validating: "Kept note")), phase: .ready))
		try FileModelCatalogCache(directory: directory).replaceAtomically(.fixture)
		guard let defaults = UserDefaults(suiteName: suite) else {
			preconditionFailure("The test defaults suite cannot be opened")
		}
		defaults.set(Self.phone.rawValue, forKey: "enduragent.deviceId")
		defaults.set(true, forKey: "enduragent.onboardingCompleted")
		defaults.set("other", forKey: "other.setting")
	}

	func seedRecords() async throws {
		try await records.append(
			[
				storedRecord(
					device: Self.phone, wall: 1,
					body: .synced(sampleUser(chatId: .main, text: "synced"))),
				storedRecord(
					device: DeviceID(rawValue: "other-phone"), wall: 2,
					body: .synced(sampleUser(chatId: .main, text: "from another phone"))),
			], locality: .synced)
		try await records.append(
			[storedRecord(device: Self.phone, wall: 3, body: .deviceLocal(sampleLocal()))],
			locality: .deviceLocal)
	}

	func begin(_ coach: Coach, _ scope: ErasureScope = .everything) async throws -> ErasureRun {
		guard case .begun(let run) = await coach.beginErasure(device, scope) else {
			throw ErasureRigFailure.busy
		}
		return run
	}

	func waitUntilSyncedRowsAreGone() async throws {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while try await !records.fetch(RecordQuery(scope: .everySynced)).records.isEmpty,
			ContinuousClock.now < deadline
		{
			try await Task.sleep(for: .milliseconds(10))
		}
		try #require(try await records.fetch(RecordQuery(scope: .everySynced)).records.isEmpty)
	}

	func fail(_ step: ErasureStep) throws {
		switch step {
		case .iCloud: records.failErasures = [.synced]
		case .deviceRecords: records.failErasures = [.deviceLocal]
		case .files:
			try FileManager.default.setAttributes(
				[.posixPermissions: 0o500], ofItemAtPath: directory.path)
		case .keychain: backing.unavailable = true
		}
	}

	func recover(_ step: ErasureStep) throws {
		records.failErasures = []
		backing.unavailable = false
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o700], ofItemAtPath: directory.path)
	}

	func expectEverythingErased(iCloudPending: Bool) async throws {
		#expect(try await records.fetch(RecordQuery(scope: .everySynced)).records.isEmpty)
		#expect(try await records.fetch(RecordQuery(scope: .everyDeviceLocal)).records.isEmpty)
		let store = ICloudKeychainStore(backing: backing)
		#expect(try store.creditsAccount() == nil)
		#expect(try store.intervalsConnection() == nil)
		#expect(try store.openRouterAccountKey(at: .legacy) == nil)
		#expect(try support.journal.read() == nil)
		#expect(try support.keptNotes.load() == nil)
		#expect(try FileModelCatalogCache(directory: directory).load() == nil)
		let defaults = try #require(UserDefaults(suiteName: suite))
		#expect(defaults.string(forKey: "enduragent.deviceId") == nil)
		#expect(defaults.object(forKey: "enduragent.onboardingCompleted") == nil)
		#expect(defaults.string(forKey: "other.setting") == "other")
		#expect(device.erasure == (iCloudPending ? .iCloudPending(began: Self.began) : nil))
	}

	func expectNothingErased() async throws {
		#expect(try await records.fetch(RecordQuery(scope: .everySynced)).records.count == 2)
		#expect(try await records.fetch(RecordQuery(scope: .everyDeviceLocal)).records.count == 1)
		let store = ICloudKeychainStore(backing: backing)
		#expect(try store.creditsAccount()?.key == testKey)
		#expect(try store.intervalsConnection() == testConnection)
		#expect(try support.keptNotes.load() != nil)
		#expect(try FileModelCatalogCache(directory: directory).load() != nil)
		let defaults = try #require(UserDefaults(suiteName: suite))
		#expect(defaults.string(forKey: "enduragent.deviceId") == Self.phone.rawValue)
	}
}
