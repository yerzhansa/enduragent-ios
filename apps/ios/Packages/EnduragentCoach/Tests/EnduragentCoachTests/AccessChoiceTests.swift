import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct AccessChoiceTests {
	let creditsKey = "synthetic-credits"

	@Test(arguments: ["missing", "blank", "malformed", "locked"])
	func creditsNeverClaimMissingOrUnreadableSetup(_ fault: String) async throws {
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
		#expect(status.access.model == testModel)
		if fault == "locked" {
			#expect(status.access.availability == .unavailable(.secureStorageLocked))
			#expect(status.setup == .accessTemporarilyUnavailable(.secureStorageLocked))
		} else {
			let availability: AccessAvailability =
				fault == "malformed"
				? .unavailable(.malformedStoredCredential(.creditsAccount)) : .needsSetup
			#expect(status.access.availability == availability)
			#expect(status.setup != .ready)
		}
		#expect(transport.requestCount == 0)
	}

	@Test(arguments: ["openRouterAccount", "consentSelection", "malformed"])
	func savedBuild9SelectionReadsAsCredits(_ saved: String) async throws {
		let fixture = try fixture()
		try fixture.store.storeCreditsAccount(
			CreditsAccount(appAccountToken: UUID(), key: creditsKey))
		try fixture.backing.installBuild9OpenRouterChoice(
			model: ModelID(rawValue: "test/account-model"), key: "synthetic-openrouter-account")
		let selection = CredentialSlot.accessSelection.rawValue
		switch saved {
		case "consentSelection":
			try fixture.backing.update(
				account: selection,
				data: Data(#"{"consentSelection":{"_0":"\#(UUID().uuidString)"}}"#.utf8))
		case "malformed":
			try fixture.backing.update(account: selection, data: Data([0xFF]))
		default:
			break
		}
		let savedItems = try ["openRouterAccountKey", selection].map {
			try fixture.backing.copy(account: $0)
		}
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, store: InMemoryRecordLog(), secrets: fixture.store)
		let status = try await coach.observedStatus()
		#expect(status.access.availability == .ready)
		#expect(status.access.model == testModel)
		try await assertToolTurn(on: coach, transport: transport)
		#expect(
			try ["openRouterAccountKey", selection].map { try fixture.backing.copy(account: $0) }
				== savedItems)
	}

	private func fixture() throws -> (
		directory: URL, store: ICloudKeychainStore, backing: FixtureSecretStoreBacking
	) {
		let directory = try TestTemporaryFolders.make()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let fixture = try ICloudKeychainStore.fixture(directory: directory)
		return (directory, fixture.store, fixture.backing)
	}

	private func assertToolTurn(on coach: Coach, transport: FakeModelTransport) async throws {
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
				$0.credential.secret == creditsKey && $0.credential.method == .credits
					&& $0.model == testModel
			})
		let continuation = try #require(requests.last)
		#expect(continuation.messages.contains { $0.role == .tool })
	}
}
