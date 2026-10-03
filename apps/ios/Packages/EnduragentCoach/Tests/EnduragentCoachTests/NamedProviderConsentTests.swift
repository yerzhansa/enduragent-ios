import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension ProviderConsentTests {
	@Test func legacyAgreementCannotAuthorizeASyncedProviderAndFailedSaveSendsNothing() async throws
	{
		try await seed(
			store,
			[
				storedRecord(
					device: store.deviceId, wall: 1,
					body: .deviceLocal(.providerConsent(ProviderConsent(legacyAt: clock.now))))
			])
		let secrets = keyedSecrets()
		let selected = try #require(ModelCatalog.bundled.orderedEntries.last)
		try secrets.installOpenRouterChoice(
			model: selected.id, key: "synthetic-synced-key", catalog: .bundled)
		let log = FaultInjectingRecordLog(wrapping: store)
		let coach = namedCoach(secrets: secrets, log: log)
		let challenge = try await challenge(coach)
		#expect(challenge.target.method == .openRouterAccount)
		#expect(challenge.target.entry.details.displayName == "Claude Sonnet 4.5")
		#expect(challenge.target.entry.details.provider.name == "Anthropic")
		await coach.declineConsent(challenge)
		#expect(
			failure(try await coach.sendAndSettle("Before agreement"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
		let retry = try await self.challenge(coach)
		log.failNextAppend = true
		await #expect(throws: ConsentWriteFailure.notSaved) { try await coach.recordConsent(retry) }
		#expect(
			failure(try await coach.sendAndSettle("After failed save"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
		try await coach.recordConsent(retry)
		transport.respond = { _ in ScriptedReply([.text("Agreed."), .finish(reason: .stop)]) }
		#expect(replyText(try await coach.sendAndSettle("After agreement")) == "Agreed.")
		#expect(transport.requests.last?.provider == selected.details.provider)
		let reopened = namedCoach(secrets: secrets, log: store)
		#expect(try await reopened.observedStatus().acceptedConsent?.target == challenge.target)
		#expect(try await reopened.observedStatus().needsProviderConsent == false)
	}

	@Test func staleAcceptanceCannotAgreeToALaterChoice() async throws {
		let secrets = keyedSecrets()
		let coach = namedCoach(secrets: secrets, log: store)
		let old = try await challenge(coach)
		_ = await coach.changeModelAccess(.useCredits)
		await #expect(throws: ConsentWriteFailure.staleChallenge) {
			try await coach.recordConsent(old)
		}
		#expect(try await coach.observedStatus().acceptedConsent == nil)
		#expect(
			failure(try await coach.sendAndSettle("Stale agreement"))
				== .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 0)
	}

	@Test func providerProposalWaitsForConsentAndDeclineKeepsTheSavedModel() async throws {
		let secrets = keyedSecrets()
		let first = try #require(ModelCatalog.bundled.orderedEntries.first)
		let last = try #require(ModelCatalog.bundled.orderedEntries.last)
		try secrets.installOpenRouterChoice(
			model: first.id, key: "synthetic-proposal-key", catalog: .bundled)
		let coach = namedCoach(secrets: secrets, log: store)
		try await coach.recordConsent(try await challenge(coach))
		let saved = try secrets.accessSelection()
		_ = await coach.changeModelAccess(.selectOpenRouterModel(last.id))
		let proposed = try await challenge(coach)
		#expect(proposed.target.entry == last)
		#expect(try secrets.accessSelection() == saved)
		#expect(try await coach.observedStatus().access.model == first.id)
		await coach.declineConsent(proposed)
		#expect(try secrets.accessSelection() == saved)
		#expect(try await coach.observedStatus().needsProviderConsent == false)
		await #expect(throws: ConsentWriteFailure.staleChallenge) {
			try await coach.recordConsent(proposed)
		}
		_ = await coach.changeModelAccess(.selectOpenRouterModel(last.id))
		try await coach.recordConsent(try await challenge(coach))
		#expect(try await coach.observedStatus().access.model == last.id)
		transport.respond = { _ in ScriptedReply([.text("New provider."), .finish(reason: .stop)]) }
		#expect(
			replyText(try await coach.sendAndSettle("Use the agreed provider")) == "New provider.")
		#expect(transport.requests.last?.provider == last.details.provider)
	}

	@Test func aFailedProposalConsentWriteKeepsTheOldModel() async throws {
		let backing = FixtureSecretStoreBacking()
		let secrets = keyedSecrets(backing: backing)
		let first = try #require(ModelCatalog.bundled.orderedEntries.first)
		let last = try #require(ModelCatalog.bundled.orderedEntries.last)
		try secrets.installOpenRouterChoice(
			model: first.id, key: "synthetic-proposal-key", catalog: .bundled)
		let log = FaultInjectingRecordLog(wrapping: store)
		let coach = namedCoach(secrets: secrets, log: log)
		try await coach.recordConsent(try await challenge(coach))
		let saved = try secrets.accessSelection()
		_ = await coach.changeModelAccess(.selectOpenRouterModel(last.id))
		let proposed = try await challenge(coach)
		log.failNextAppend = true
		await #expect(throws: ConsentWriteFailure.notSaved) {
			try await coach.recordConsent(proposed)
		}
		#expect(try secrets.accessSelection() == saved)
		#expect(transport.requestCount == 0)
		await coach.declineConsent(proposed)
		#expect(try await coach.observedStatus().needsProviderConsent == false)
	}

	@Test func toolContinuationRechecksTheAgreedRecipient() async throws {
		let secrets = keyedSecrets()
		let first = try #require(ModelCatalog.bundled.orderedEntries.first)
		try secrets.installOpenRouterChoice(
			model: first.id, key: "synthetic-held-key", catalog: .bundled)
		let delayed = HeldClock()
		let transport = FakeModelTransport(
			clock: delayed,
			respond: { _ in
				ScriptedReply(
					[
						.toolCall(name: "get_activities", arguments: #"{"days":7}"#),
						.finish(reason: .toolCalls),
					], requestDelay: .seconds(1))
			})
		var ports = CoachPorts(
			records: RecordStore(log: store), secrets: secrets,
			models: .scripted(transport, catalog: .bundled),
			training: .fake { _, _ in FakeIntervalsClient(athleteName: "Synthetic Rider", ftp: 250)
			}, credits: .fake(FakeCreditsClient()),
			host: ImmediateExecutionHost(), clock: clock)
		ports.watchdogSleep = HeldClock().sleep
		let coach = Coach(
			sport: .cycling, ports: ports, builtInModel: first.id,
			displayLocale: testDisplayLocale, coalescing: quickWindow)
		try await coach.recordConsent(try await challenge(coach))
		let turn = try #require(
			try await coach.send(draft("Read my training"), to: .main).acceptedTurn)
		try await delayed.waitUntilHeld(.seconds(1))
		_ = await coach.changeModelAccess(.useCredits)
		try await coach.recordConsent(try await challenge(coach))
		delayed.release(.seconds(1))
		let settled = try #require(await coach.settledState(of: turn, in: .main))
		#expect(failure(settled) == .model(.accessUnavailable(.providerConsentRequired)))
		#expect(transport.requestCount == 1)
	}

	private func namedCoach(secrets: any SecretStore, log: any RecordLog) -> Coach {
		Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: RecordStore(log: log), secrets: secrets,
				models: .scripted(transport, catalog: .bundled),
				training: .fake { _, _ in
					FakeIntervalsClient(athleteName: "Synthetic Rider", ftp: 250)
				},
				credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(), clock: clock),
			builtInModel: ModelCatalog.bundled.orderedEntries[0].id,
			displayLocale: testDisplayLocale, coalescing: quickWindow)
	}

	private func challenge(_ coach: Coach) async throws -> ConsentChallenge {
		guard case .required(let challenge) = try await coach.observedStatus().access.consent else {
			throw ConsentWriteFailure.staleChallenge
		}
		return challenge
	}
}
