import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

@Suite struct ProviderConsentTests {
	let store = InMemoryRecordLog()
	let transport = FakeModelTransport()
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

	@Test func aRefusedTurnOffersRetryAfterConsent() async throws {
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, consent: false)
		let turn = try #require(try await coach.send(draft("Hello"), to: .main).acceptedTurn)
		let refused = try #require(await coach.settledState(of: turn, in: .main))
		guard case .failed(let refusal) = refused else {
			Issue.record("Expected a consent refusal")
			return
		}
		#expect(failure(refused) == .model(.accessUnavailable(.providerConsentRequired)))
		#expect(refused.retryable)
		#expect(refusal.notice.action == .tryAgain(turn))
		#expect(transport.requestCount == 0)
		try await coach.recordConsent()
		transport.script = [.text("Hello."), .finish(reason: .stop)]
		try await coach.retry(turn, in: .main)
		let answered = try #require(await coach.settledState(of: turn, in: .main))
		#expect(replyText(answered) == "Hello.")
		#expect(transport.requestCount == 1)
		#expect(await coach.transcript(.main) == ["Hello", "Hello."])
	}

	@Test func setupRequiresConsentBeforeItIsReady() async throws {
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, consent: false)
		#expect(await coach.status().setup == .needsProviderConsent)
		try await coach.recordConsent()
		#expect(await coach.status().setup == .ready)
	}

	@Test func consentPayloadPreservesTheStoredDateFormat() throws {
		let consent = ProviderConsent(at: Date(timeIntervalSinceReferenceDate: 123))
		let row = try StoredAthleteRecord(
			record: storedRecord(
				device: store.deviceId, wall: 1, body: .deviceLocal(.providerConsent(consent))))
		let payload = Data(#"{"at":123,"version":1}"#.utf8)
		#expect(row.body == payload)
		row.body = payload
		#expect(try row.decode().get().body == .deviceLocal(.providerConsent(consent)))
	}

	@Test func consentUsesTheCurrentVersionAndIsIndependentOfAccessMethod() async throws {
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, consent: false)
		#expect(await coach.status().providerConsent == nil)
		#expect(await coach.status().needsProviderConsent)
		try await coach.recordConsent()
		try await coach.recordConsent()
		let consent = try #require(await coach.status().providerConsent)
		#expect(consent.version == ProviderConsent.currentVersion)
		#expect(consent.at == clock.now)
		#expect(await coach.status().needsProviderConsent == false)
		let records = try await store.fetch(RecordQuery(scope: .deviceLocal([.providerConsent])))
		#expect(records.records.count == 1)
		#expect(try await store.fetch(RecordQuery(scope: .everySynced)).records.isEmpty)
		let reopened = await makeCoach(
			transport: transport, store: store, clock: clock, consent: false)
		_ = await reopened.changeModelAccess(.useCredits)
		#expect(await reopened.status().providerConsent == consent)
	}

	@Test(arguments: [0, ProviderConsent.currentVersion + 1])
	func anotherConsentVersionRequiresAcceptance(version: Int) async throws {
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId, wall: 1,
					body: .deviceLocal(
						.providerConsent(ProviderConsent(version: version, at: clock.now))))
			])
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, consent: false)
		#expect(await coach.status().needsProviderConsent)
		#expect(
			failure(try await coach.sendAndSettle("Hello"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
		try await coach.recordConsent()
		transport.script = [.text("Hello."), .finish(reason: .stop)]
		#expect(replyText(try await coach.sendAndSettle("Hello")) == "Hello.")
	}

	@Test func anotherDevicesConsentDoesNotAuthorizeThisDevice() async throws {
		try await seed(
			store,
			[
				storedRecord(
					device: DeviceID(rawValue: "another-test-device"), wall: 1,
					body: .deviceLocal(.providerConsent(ProviderConsent(at: clock.now))))
			])
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, consent: false)
		#expect(await coach.status().needsProviderConsent)
		#expect(
			failure(try await coach.sendAndSettle("Hello"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
	}

	@Test func aFailedConsentWriteKeepsModelWorkBlocked() async throws {
		let log = FaultInjectingRecordLog(wrapping: store)
		try log.failAppends(ofKind: "providerConsent")
		let coach = await makeCoach(transport: transport, store: log, clock: clock, consent: false)
		await #expect(throws: PreferenceWriteFailure.notSaved) { try await coach.recordConsent() }
		#expect(await coach.status().needsProviderConsent)
		#expect(
			failure(try await coach.sendAndSettle("Hello"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
	}

	@Test func anUnreadableConsentRecordKeepsModelWorkBlocked() async throws {
		let original = await makeCoach(transport: transport, store: store, clock: clock)
		#expect(await original.status().needsProviderConsent == false)
		let coach = await makeCoach(
			transport: transport, store: UnreadableConsentLog(inner: store), clock: clock,
			consent: false)
		#expect(await coach.status().needsProviderConsent)
		#expect(
			failure(try await coach.sendAndSettle("Hello"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
		#expect(
			coach.diagnostics.entries.contains { $0.event == .preferencesUnavailable(.unavailable) }
		)
	}

	@Test func legacyAccessSelectionDoesNotGrantProviderConsent() async throws {
		let backing = MemorySecretStoreBacking(items: [
			"openRouterAccountKey": Data("sk-or-test-account".utf8),
			"accessSelection": Data(
				#"{"openRouterAccount":{"model":"test/coach-model","provider":"Test Provider","consentModel":"test/coach-model","consentAt":0}}"#
					.utf8),
		])
		let secrets = ICloudKeychainStore(backing: backing)
		#expect(try secrets.accessSelection() == .openRouterAccount(model: testModel))
		let coach = await makeCoach(
			transport: transport, store: store, clock: clock, secrets: secrets, consent: false)
		#expect(
			failure(try await coach.sendAndSettle("Hello"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
	}
}

extension SwiftDataSuites {
	@Test static func malformedConsentDoesNotPreventLaterAcceptance() async throws {
		let directory = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-consent-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let local = try ModelContainerHandle.withoutCloudKit(
			storeURL: directory.appending(path: "local.store"))
		let device = DeviceID(rawValue: "consent-test-device")
		let record = try StoredAthleteRecord(
			record: storedRecord(
				device: device, wall: 1,
				body: .deviceLocal(
					.providerConsent(ProviderConsent(at: Date(timeIntervalSince1970: 1))))))
		record.body = Data(#"{"version":1,"at":"invalid"}"#.utf8)
		let context = ModelContext(local.container)
		context.insert(record)
		try context.save()
		let log = SwiftDataRecordLog(
			deviceId: device,
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: directory.appending(path: "synced.store")), local: local)
		let transport = FakeModelTransport()
		let coach = await makeCoach(transport: transport, store: log, consent: false)
		#expect(await coach.status().needsProviderConsent)
		#expect(
			failure(try await coach.sendAndSettle("Hello"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
		try await coach.recordConsent()
		let reopened = await makeCoach(transport: transport, store: log, consent: false)
		#expect(await reopened.status().needsProviderConsent == false)
		transport.script = [.text("Hello."), .finish(reason: .stop)]
		#expect(replyText(try await reopened.sendAndSettle("Hello again")) == "Hello.")
		#expect(transport.requestCount == 1)
		let page = try await log.fetch(RecordQuery(scope: .deviceLocal([.providerConsent])))
		#expect(page.records.count == 1)
		#expect(page.skipped == [.malformed(kind: "providerConsent", ulid: record.ulid)])
		#expect(
			coach.diagnostics.entries.contains {
				$0.event == .skippedRecord(.malformed(kind: "providerConsent", ulid: record.ulid))
			})
	}

	@Test static func providerConsentReopensFromTheDeviceLocalStore() async throws {
		let directory = FileManager.default.temporaryDirectory.appending(
			path: "enduragent-consent-\(UUID().uuidString)", directoryHint: .isDirectory)
		let device = DeviceID(rawValue: "consent-test-device")
		let fixture = try RecordStore.fixture(directory: directory, deviceId: device)
		let coach = await makeCoach(
			transport: FakeModelTransport(), store: fixture.store.log, consent: false)
		try await coach.recordConsent()
		let consent = try #require(await coach.status().providerConsent)
		let reopened = try RecordStore.fixture(directory: directory, deviceId: device)
		let next = await makeCoach(
			transport: FakeModelTransport(), store: reopened.store.log, consent: false)
		#expect(await next.status().providerConsent == consent)
		#expect(await next.status().needsProviderConsent == false)
		#expect(
			try await reopened.store.log.fetch(RecordQuery(scope: .everySynced)).records.isEmpty)
	}
}

private struct UnreadableConsentLog: RecordLog {
	let inner: InMemoryRecordLog
	var deviceId: DeviceID { inner.deviceId }
	var imports: AsyncStream<Void> { inner.imports }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage {
		guard query.scope != .deviceLocal([.providerConsent]) else {
			throw LedgerFailure.unavailable
		}
		return try await inner.fetch(query)
	}
}
