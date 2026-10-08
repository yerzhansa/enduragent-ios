import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct AccessChoiceTests {
	let accountModel = ModelID(rawValue: "test/account-model")
	let accountKey = "synthetic-openrouter-account"
	let creditsKey = "synthetic-credits"

	@Test(arguments: ["missing", "blank", "malformed", "locked"])
	func defaultCreditsNeverClaimsMissingOrUnreadableSetup(_ fault: String) async throws {
		let fixture = try fixture()
		if fault == "blank" {
			try fixture.store.storeCreditsAccount(
				CreditsAccount(appAccountToken: UUID(), key: " \n "))
		}
		if fault == "malformed" {
			try fixture.backing.add(
				account: CredentialSlot.creditsAccount.rawValue, data: Data([0xFF]))
		}
		fixture.backing.locked = fault == "locked"
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), secrets: fixture.store)
		let status = try await coach.observedStatus()
		#expect(status.access.selection == nil)
		#expect(status.access.savedMethod == nil)
		if fault == "locked" {
			#expect(status.access.model == nil)
			#expect(status.access.availability == .unavailable(.secureStorageLocked))
			#expect(status.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		} else {
			#expect(status.access.model == testModel)
			let availability: AccessAvailability =
				fault == "malformed"
				? .unavailable(.malformedStoredCredential(.creditsAccount)) : .needsSetup
			#expect(status.access.availability == availability)
			#expect(status.setup != .ready)
		}
		let outcome = await coach.changeModelAccess(.useCredits)
		guard case .failedPreviousKept(.secureStorage, previous: nil) = outcome else {
			Issue.record("Missing or unreadable Credits setup must refuse selection")
			return
		}
		fixture.backing.locked = false
		#expect(try fixture.store.accessSelection() == nil)
		#expect(transport.requestCount == 0)
	}

	@Test func choosingCreditsPublishesAndSurvivesReopen() async throws {
		let fixture = try fixture()
		let reference = OpenRouterCredentialRef.generation(UUID())
		try seedBothIdentities(in: fixture.store, reference: reference)
		let transport = FakeModelTransport()
		let records = InMemoryRecordLog()
		let coach = await makeCoach(transport: transport, store: records, secrets: fixture.store)
		let statuses = await coach.observeStatus()
		let initial = try #require(try await statuses.status { _ in true })
		#expect(initial.access.savedMethod == .openRouterAccount)
		#expect(initial.access.model == accountModel)
		#expect(
			await coach.changeModelAccess(.useCredits)
				== .replaced(AccessSummary(selection: .credits), authority: nil))
		try await coach.recordConsent()
		let selected = try #require(
			try await statuses.status {
				$0.access.savedMethod == .credits && !$0.needsProviderConsent
			})
		#expect(selected.access.selection == .credits)
		#expect(selected.access.model == testModel)
		#expect(selected.access.availability == .ready)
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		#expect(try reopened.accessSelection() == .init(.credits))
		let next = await makeCoach(
			transport: transport, store: records, secrets: reopened, consent: false)
		#expect(try await next.observedStatus().access == selected.access)
		try await assertToolTurn(
			on: next, transport: transport, method: .credits, key: creditsKey, model: testModel)
		#expect(try reopened.creditsAccount()?.key == creditsKey)
		#expect(try fixture.store.creditsAccount() == reopened.creditsAccount())
		#expect(try reopened.openRouterAccountKey(at: reference) == accountKey)
	}

	@Test(arguments: [false, true])
	func savedOpenRouterChoiceSurvivesReopen(legacy: Bool) async throws {
		let fixture = try fixture()
		let reference: OpenRouterCredentialRef = legacy ? .legacy : .generation(UUID())
		try seedBothIdentities(in: fixture.store, reference: reference)
		if legacy {
			try fixture.backing.update(
				account: CredentialSlot.accessSelection.rawValue,
				data: Data(#"{"openRouterAccount":{"model":"test/account-model"}}"#.utf8))
		}
		let savedBytes = try fixture.backing.copy(account: CredentialSlot.accessSelection.rawValue)
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), secrets: reopened)
		let status = try await coach.observedStatus()
		#expect(status.access.savedMethod == .openRouterAccount)
		#expect(status.access.availability == .ready)
		#expect(status.access.model == accountModel)
		guard case .openRouterAccount(let choice) = status.access.selection else {
			Issue.record("Expected the reopened OpenRouter choice")
			return
		}
		#expect(choice.model == accountModel)
		try await assertToolTurn(
			on: coach, transport: transport, method: .openRouterAccount, key: accountKey,
			model: accountModel)
		let after = try ICloudKeychainStore.fixture(directory: fixture.directory)
		#expect(try after.store.accessSelection() == savedSelection(reference))
		#expect(
			try after.backing.copy(account: CredentialSlot.accessSelection.rawValue) == savedBytes)
		#expect(try after.store.openRouterAccountKey(at: reference) == accountKey)
		#expect(try after.store.creditsAccount()?.key == creditsKey)
	}

	@Test(arguments: ["missing", "blank", "credentialLocked", "locked", "selectionWrite"])
	func failedCreditsChangePreservesOpenRouter(_ fault: String) async throws {
		let fixture = try fixture()
		let reference = OpenRouterCredentialRef.generation(UUID())
		try seedBothIdentities(in: fixture.store, reference: reference)
		if fault == "missing" { try fixture.store.delete(.creditsAccount) }
		if fault == "blank" {
			let account = try #require(try fixture.store.creditsAccount())
			try fixture.store.storeCreditsAccount(
				CreditsAccount(appAccountToken: account.appAccountToken, key: " \n "))
		}
		let originalAccount = try fixture.store.creditsAccount()
		let transport = FakeModelTransport()
		let records = InMemoryRecordLog()
		let coach = await makeCoach(transport: transport, store: records, secrets: fixture.store)
		let previous = try await coach.observedStatus().access
		if fault == "credentialLocked" {
			fixture.backing.fail(
				CredentialSlot.creditsAccount.rawValue, with: errSecInteractionNotAllowed)
		}
		fixture.backing.locked = fault == "locked"
		if fault == "selectionWrite" {
			fixture.backing.failWrites(
				CredentialSlot.accessSelection.rawValue, with: errSecNotAvailable)
		}
		let outcome = await coach.changeModelAccess(.useCredits)
		let expected: AccessUnavailable =
			switch fault {
			case "missing", "blank": .notConfigured(.credits)
			case "credentialLocked", "locked": .secureStorageLocked
			default: .secureStorageUnavailable
			}
		#expect(
			outcome
				== .failedPreviousKept(
					.secureStorage(expected),
					previous: fault == "locked"
						? nil : previous.selection.map { AccessSummary(selection: $0) }))
		fixture.backing.locked = false
		fixture.backing.fail(CredentialSlot.creditsAccount.rawValue, with: nil)
		fixture.backing.failWrites(CredentialSlot.accessSelection.rawValue, with: nil)
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		#expect(try reopened.accessSelection() == savedSelection(reference))
		#expect(try reopened.creditsAccount() == originalAccount)
		#expect(try reopened.openRouterAccountKey(at: reference) == accountKey)
		#expect(try await coach.observedStatus().access == previous)
		let next = await makeCoach(
			transport: transport, store: records, secrets: reopened, consent: false)
		#expect(try await next.observedStatus().access == previous)
		try await assertToolTurn(
			on: next, transport: transport, method: .openRouterAccount, key: accountKey,
			model: accountModel)
	}

	@Test func syncedChoiceRequiresDeviceLocalConsent() async throws {
		let fixture = try fixture()
		let reference = OpenRouterCredentialRef.generation(UUID())
		try seedBothIdentities(in: fixture.store, reference: reference)
		let firstLog = InMemoryRecordLog(deviceId: DeviceID(rawValue: "access-first-device"))
		let first = await makeCoach(
			transport: FakeModelTransport(), store: firstLog, secrets: fixture.store)
		let selected = try await first.observedStatus().access
		let consentRecords = try await firstLog.fetch(
			RecordQuery(scope: .deviceLocal([.providerConsent])))
		#expect(consentRecords.records.count == 1)
		let secondLog = InMemoryRecordLog(deviceId: DeviceID(rawValue: "access-second-device"))
		try await secondLog.append(consentRecords.records, locality: .deviceLocal)
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory)
		let transport = FakeModelTransport()
		let second = await makeCoach(
			transport: transport, store: secondLog, secrets: reopened.store, consent: false)
		let status = try await second.observedStatus()
		#expect(status.access.selection == selected.selection)
		#expect(status.needsProviderConsent)
		#expect(status.acceptedConsent == nil)
		#expect(
			failure(try await second.sendAndSettle("Read my training notes"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
		try await second.recordConsent()
		try await assertToolTurn(
			on: second, transport: transport, method: .openRouterAccount, key: accountKey,
			model: accountModel)
	}

	@Test(arguments: ["missing", "blank", "locked"])
	func incompleteSyncedChoiceKeepsItsMarkAndSendsNothing(_ fault: String) async throws {
		let fixture = try fixture()
		let reference = OpenRouterCredentialRef.generation(UUID())
		try fixture.store.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: creditsKey))
		try fixture.store.storeAccessSelection(savedSelection(reference))
		if fault == "blank" { try fixture.store.storeOpenRouterAccountKey(" \n ", at: reference) }
		if fault == "locked" {
			fixture.backing.fail(reference.account, with: errSecInteractionNotAllowed)
		}
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), secrets: fixture.store)
		let status = try await coach.observedStatus()
		#expect(status.access.selection == nil)
		#expect(status.access.savedMethod == .openRouterAccount)
		#expect(status.access.model == accountModel)
		#expect(
			status.access.availability
				== (fault == "locked" ? .unavailable(.secureStorageLocked) : .needsSetup))
		let expected: AccessUnavailable =
			fault == "locked" ? .secureStorageLocked : .notConfigured(.openRouterAccount)
		#expect(
			failure(try await coach.sendAndSettle("Read my training notes"))
				== .model(.accessUnavailable(expected)))
		#expect(transport.requestCount == 0)
		fixture.backing.fail(reference.account, with: nil)
		try fixture.store.storeOpenRouterAccountKey(accountKey, at: reference)
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		let next = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), secrets: reopened)
		#expect(try await next.observedStatus().access.availability == .ready)
		try await assertToolTurn(
			on: next, transport: transport, method: .openRouterAccount, key: accountKey,
			model: accountModel)
	}

	private func fixture() throws -> (
		directory: URL, store: ICloudKeychainStore, backing: FixtureSecretStoreBacking
	) {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let fixture = try ICloudKeychainStore.fixture(directory: directory)
		return (directory, fixture.store, fixture.backing)
	}

	@Test(arguments: [false, true])
	func disconnectRemovesOnlyTheSelectedOpenRouterCredential(legacy: Bool) async throws {
		let fixture = try fixture()
		let reference: OpenRouterCredentialRef = legacy ? .legacy : .generation(UUID())
		try seedBothIdentities(in: fixture.store, reference: reference)
		let other = OpenRouterCredentialRef.generation(UUID())
		try fixture.store.storeOpenRouterAccountKey("synthetic-other-credential", at: other)
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), secrets: fixture.store)
		#expect(await coach.changeModelAccess(.disconnectOpenRouter) == .disconnected)
		let status = try await coach.observedStatus()
		#expect(status.access.selection == nil)
		#expect(status.access.savedMethod == .openRouterAccount)
		#expect(status.access.model == accountModel)
		#expect(status.access.availability == .needsSetup)
		#expect(
			failure(try await coach.sendAndSettle("Read my training notes"))
				== .model(.accessUnavailable(.notConfigured(.openRouterAccount))))
		#expect(transport.requestCount == 0)
		let reopened = try ICloudKeychainStore.fixture(directory: fixture.directory).store
		#expect(try reopened.accessSelection() == savedSelection(reference))
		#expect(try reopened.openRouterAccountKey(at: reference) == nil)
		#expect(try reopened.openRouterAccountKey(at: other) == "synthetic-other-credential")
		#expect(try reopened.creditsAccount()?.key == creditsKey)
	}

	private func savedSelection(_ reference: OpenRouterCredentialRef) -> SavedAccessReference {
		.init(.openRouter(SavedOpenRouterReference(credential: reference, model: accountModel)))
	}

	private func seedBothIdentities(
		in store: ICloudKeychainStore, reference: OpenRouterCredentialRef
	) throws {
		try store.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: creditsKey))
		try store.storeOpenRouterAccountKey(accountKey, at: reference)
		try store.storeAccessSelection(savedSelection(reference))
	}

	private func assertToolTurn(
		on coach: Coach, transport: FakeModelTransport, method: AccessMethod, key: String,
		model: ModelID
	) async throws {
		transport.respond = ScriptedReply.sequence([
			.text("I'll read your notes."),
			.toolCall(name: "memory_query", arguments: #"{"from":"1998-06-01","to":"1998-06-13"}"#),
			.finish(reason: .toolCalls),
			.text("Your notes are checked."), .finish(reason: .stop),
		])
		#expect(
			replyText(try await coach.sendAndSettle("Read my training notes"))
				== "Your notes are checked.")
		let requests = transport.requests
		#expect(requests.count == 2)
		#expect(
			requests.allSatisfy {
				$0.credential.secret == key && $0.credential.method == method
					&& $0.model == model
			})
		let continuation = try #require(requests.last)
		#expect(continuation.messages.contains { $0.role == .tool })
	}
}
