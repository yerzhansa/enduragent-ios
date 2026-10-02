import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct CredentialCorrectionTests {
	let basis: CredentialVaultTests
	let backing = FixtureSecretStoreBacking()
	let secrets: ICloudKeychainStore

	init() throws {
		basis = try CredentialVaultTests()
		secrets = ICloudKeychainStore(backing: backing)
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		try secrets.storeOpenRouterAccountKey("synthetic-router-key")
		try secrets.storeAccessSelection(.credits)
	}

	@Test func malformedCorrectionIsAtomicAndUsesNewOwner() async throws {
		try backing.corruptIntervalsConnection()
		let malformed = try backing.copy(account: CredentialSlot.intervalsConnection.rawValue)
		let credits = try secrets.creditsAccount()
		let coach = await basis.coach(secrets)
		let statuses = await coach.observeStatus()
		let unavailable = try #require(try await statuses.status { _ in true })
		#expect(
			unavailable.training == .unavailable(.malformedStoredCredential(.intervalsConnection)))
		#expect(unavailable.training.notice?.key == Catalog.connectErrorStorageMalformed)
		#expect(await coach.changeTraining(.keep) == .kept(nil))
		#expect(
			await coach.changeTraining(.replace(apiKey: " \n ", athlete: .keyOwner))
				== .refused(.blankConnection))
		#expect(try backing.copy(account: CredentialSlot.intervalsConnection.rawValue) == malformed)
		backing.failNextWrite = true
		#expect(
			await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
				== .failedPreviousKept(.secureStorage(.secureStorageUnavailable), previous: nil))
		#expect(try backing.copy(account: CredentialSlot.intervalsConnection.rawValue) == malformed)
		let result = await coach.changeTraining(
			.replace(apiKey: "other-athlete", athlete: .keyOwner))
		guard case .replaced = result else {
			Issue.record("The malformed connection was not corrected")
			return
		}
		let saved = try #require(try secrets.intervalsConnection())
		#expect(saved.credential == .apiKey("other-athlete"))
		#expect(saved.resolvedAthlete?.rawValue == "i2002")
		#expect(try secrets.creditsAccount() == credits)
		#expect(try secrets.openRouterAccountKey() == "synthetic-router-key")
		#expect(try secrets.accessSelection() == .credits)
		basis.transport.respond = ScriptedReply.sequence([
			.toolCall(name: ToolName.intervalsFetchAthlete.rawValue, arguments: "{}"),
			.finish(reason: .toolCalls), .text("Profile read."), .finish(reason: .stop),
		])
		#expect(replyText(try await coach.sendAndSettle("Read my profile")) == "Profile read.")
		let request = try #require(basis.transport.requests.last)
		let reply = try #require(request.messages.last { $0.role == .tool })
		let data = try #require(try JSONValue.parse(reply.content).objectFields["data"])
		#expect(data.objectFields["id"] == .string("i2002"))
		#expect(data.objectFields["name"] == .string("Bo Lind"))
		#expect(
			try await coach.observedStatus().training.connectionActionTitle
				== Catalog.settingsTrainingReplace)
	}

	@Test func correctionCannotAuthorizeAnEarlierAthleteReview() async throws {
		try secrets.storeIntervalsConnection(testConnection)
		let coach = await basis.coach(secrets)
		try await coach.setLanguage(.fixed(.fr))
		let previous = try await coach.refreshedStatus()
		let identity = try await coach.creditsIdentity()
		let review = try await basis.proposeRide(on: coach)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let turn = try #require(await coach.currentSnapshot(.main)?.turns.first)
		try backing.corruptIntervalsConnection()
		guard
			case .replaced = await coach.changeTraining(
				.replace(apiKey: "other-athlete", athlete: .keyOwner))
		else {
			Issue.record("The malformed connection was not corrected")
			return
		}
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(.accountChanged))
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(
			!basis.bo.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
		#expect(await coach.currentSnapshot(.main)?.turns.first == turn)
		let current = try await coach.observedStatus()
		#expect(current.language == previous.language)
		#expect(current.session == previous.session)
		#expect(current.setup == previous.setup)
		#expect(try await coach.creditsIdentity() == identity)
		#expect(try secrets.openRouterAccountKey() == "synthetic-router-key")
		#expect(try secrets.accessSelection() == .credits)
	}

	@Test(arguments: [false, true])
	func storageRecoveryClearsNoticeWithoutLeakingContent(unavailable: Bool) async throws {
		try secrets.storeIntervalsConnection(testConnection)
		let coach = await basis.coach(secrets)
		let first = try await basis.claimAccount(after: "Keep this conversation", on: coach)
		let preserved = try #require(await coach.currentSnapshot(.main)?.turns.first)
		#expect(first == basis.account(testConnection))
		if unavailable {
			backing.unavailable = true
		} else {
			try backing.corruptIntervalsConnection()
		}
		let status = try await coach.refreshedStatus()
		#expect(
			status.training.notice?.key
				== (unavailable
					? Catalog.connectErrorStorageUnavailable : Catalog.connectErrorStorageMalformed)
		)
		let failed = try await coach.sendAndSettle("Can you read training?")
		let notice = try #require(turnNotice(of: failed))
		#expect(
			notice.key
				== (unavailable
					? Catalog.accessErrorStorageUnavailable : Catalog.connectErrorStorageMalformed))
		#expect(
			!notice.sentence(in: CatalogPhrasebook(tag: .en)).contains("fixture-malformed-secret"))
		let failedTurn = try #require(await coach.currentSnapshot(.main)?.turns.last)
		backing.unavailable = false
		if !unavailable {
			_ = await coach.changeTraining(
				.replace(apiKey: "synthetic-corrected-key", athlete: .keyOwner))
		}
		await coach.lifecycle(.becameActive)
		let recovered = try await coach.observedStatus()
		#expect(recovered.setup == .ready)
		#expect(recovered.notice?.key != notice.key)
		basis.transport.respond = ScriptedReply.sequence([
			.text("Training available."), .finish(reason: .stop),
		])
		try await coach.retry(failedTurn.id, in: .main)
		let settled = try #require(
			try await coach.waitForState(of: failedTurn.id) {
				if case .completed? = $0 { return true }
				return false
			})
		#expect(replyText(settled) == "Training available.")
		#expect(turnNotice(of: settled) == nil)
		#expect(await coach.currentSnapshot(.main)?.turns.first == preserved)
		let synced = try await basis.records.fetch(RecordQuery(scope: .everySynced))
		let local = try await basis.records.fetch(RecordQuery(scope: .everyDeviceLocal))
		let remoteMessages = basis.transport.requests.flatMap(\.messages).map(\.content)
		for text in [
			String(describing: synced), String(describing: local),
			String(describing: coach.diagnostics.entries), remoteMessages.joined(separator: "\n"),
		] {
			for secret in [
				"fixture-malformed-secret", "synthetic-corrected-key", "synthetic-router-key",
				testKey,
			] {
				#expect(!text.contains(secret))
			}
		}
	}

}
