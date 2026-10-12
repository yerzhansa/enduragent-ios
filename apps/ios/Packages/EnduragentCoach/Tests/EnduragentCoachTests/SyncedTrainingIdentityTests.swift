import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct SyncedTrainingIdentityTests {
	let fixture: CredentialVaultTests
	let backing = FixtureSecretStoreBacking()
	let secrets: ICloudKeychainStore
	let peer: FixtureTrainingPeer

	init() throws {
		fixture = try CredentialVaultTests()
		secrets = keyedSecrets(backing: backing)
		peer = FixtureTrainingPeer(
			secrets: ICloudKeychainStore(backing: backing), athleteA: fixture.ada)
	}

	@Test func resumeResolvesPeerReplacement() async throws {
		let coach = await open()
		_ = try await coach.refreshedStatus()
		let statuses = await coach.observeStatus()
		await coach.lifecycle(.enteredBackground)
		try peer.replace(.athleteB)
		await coach.lifecycle(.becameActive)
		let status = try #require(
			try await statuses.status { $0.trainingAccount?.athlete == "i2002" })
		#expect(status.training.summary?.athleteName == "Bo Lind")
		try await assertTurnUsesBo(coach)
	}

	@Test func foregroundTurnResolvesPeerReplacement() async throws {
		let coach = await open()
		_ = try await coach.refreshedStatus()
		let statuses = await coach.observeStatus()
		try peer.replace(.athleteB)
		try await assertTurnUsesBo(coach)
		let status = try #require(
			try await statuses.status { $0.trainingAccount?.athlete == "i2002" })
		#expect(status.training.summary?.athleteName == "Bo Lind")
	}

	@Test(arguments: [false, true], [false, true])
	func lateProfileCannotOverwritePeerReplacement(reusesConnectionID: Bool, localReplacement: Bool)
		async throws
	{
		let coach = await open()
		let held = fixture.ada.holdNextProfileRead()
		let oldRead = Task {
			if localReplacement {
				_ = await coach.changeTraining(
					.replace(apiKey: "fixture-held-a-key", athlete: .keyOwner))
			} else {
				await coach.lifecycle(.becameActive)
			}
		}
		defer { Task { await held.release() } }
		defer { oldRead.cancel() }
		try #require(
			try await beforeDeadline(within: .hangGuard) { await held.waitUntilEntered() } != nil)
		if reusesConnectionID {
			try ICloudKeychainStore(backing: backing).storeIntervalsConnection(
				IntervalsConnection(
					id: testConnection.id,
					credential: .apiKey(FixtureTrainingPeer.Key.athleteB.secret),
					selection: .keyOwner, resolvedAthlete: testConnection.resolvedAthlete))
		} else {
			try peer.replace(.athleteB)
		}
		try await assertTurnUsesBo(coach)
		let replacement = try #require(try secrets.intervalsConnection())
		await held.release()
		try #require(try await beforeDeadline(within: .hangGuard) { await oldRead.value } != nil)
		#expect(try secrets.intervalsConnection() == replacement)
		#expect(replacement.resolvedAthlete?.rawValue == "i2002")
		let status = try await coach.observedStatus()
		#expect(status.training.summary?.athleteName == "Bo Lind")
		#expect(status.trainingAccount?.athlete == "i2002")
	}

	@Test(arguments: UnavailablePeerState.allCases)
	func unavailableIdentityRetainsReviewWithoutWriting(_ state: UnavailablePeerState) async throws
	{
		let coach = await open()
		let review = try await fixture.proposeRide(on: coach)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let statuses = await coach.observeStatus()
		switch state {
		case .deleted: try peer.delete()
		case .rejected: try peer.replace(.rejected)
		case .unavailable: try peer.replace(.unavailable)
		case .locked: backing.locked = true
		case .revoked:
			fixture.ada.setProfileOutcome(
				.failure(IntervalsError(code: "http", details: "Revoked fixture key", status: 401)))
		}
		let block: ReviewBlock = state == .deleted ? .accountChanged : .cannotVerify
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(block))
		let retained = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(retained.ref.set == review.ref.set)
		#expect(retained.cards == review.cards)
		#expect(retained.controls == .none)
		#expect(
			retained.notice?.key
				== (state == .deleted ? Catalog.reviewAccountChanged : Catalog.reviewCannotVerify))
		#expect(fixture.ada.calls.allSatisfy { !$0.isWrite })
		#expect(peer.athleteB.calls.allSatisfy { !$0.isWrite })
		let status = try #require(try await statuses.status { state.matches($0.training) })
		#expect(state.matches(status.training))
		if state == .rejected || state == .unavailable {
			let saved = try #require(try secrets.intervalsConnection())
			#expect(
				saved.credential
					== .apiKey(
						state == .rejected
							? FixtureTrainingPeer.Key.rejected.secret
							: FixtureTrainingPeer.Key.unavailable.secret))
		}
		let cleared = try await fixture.records.fetch(
			RecordQuery(scope: .deviceLocal([.proposalCleared]), chatId: "main"))
		#expect(cleared.records.isEmpty)
	}

	@Test func sameAthletePeerRotationKeepsOriginalReviewOwner() async throws {
		let coach = await open()
		let review = try await fixture.proposeRide(on: coach)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let original = try await fixture.records.fetch(
			RecordQuery(scope: .deviceLocal([.pendingProposal]), chatId: "main"))
		try peer.replace(.rotatedA)
		await coach.lifecycle(.becameActive)
		let rotated = try #require(try secrets.intervalsConnection())
		#expect(testConnection.account.authority(under: rotated.account) == .sameAthlete)
		#expect(fixture.ada.profileReadCount >= 2)
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(fixture.ada.events.count == 1)
		#expect(peer.athleteB.events.isEmpty)
		let retained = try await fixture.records.fetch(
			RecordQuery(scope: .deviceLocal([.pendingProposal]), chatId: "main"))
		#expect(retained.records == original.records)
	}

	@Test(arguments: [false, true])
	func verifiedPeerIdentityOwnsApprovalWhenResolutionCannotBeSaved(reusesConnectionID: Bool)
		async throws
	{
		let coach = await open()
		let review = try await fixture.proposeRide(on: coach)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let replacement = IntervalsConnection(
			id: reusesConnectionID ? testConnection.id : ConnectionID(),
			credential: .apiKey(FixtureTrainingPeer.Key.athleteB.secret),
			selection: .keyOwner, resolvedAthlete: testConnection.resolvedAthlete)
		try backing.store().storeIntervalsConnection(replacement)
		backing.failWrites(CredentialSlot.intervalsConnection.rawValue, with: errSecNotAvailable)
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(.accountChanged))
		#expect(await coach.currentSnapshot(.main)?.review?.ref.set == review.ref.set)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		try await assertTurnUsesBo(coach)
		let status = try await coach.observedStatus()
		#expect(status.trainingAccount?.athlete == "i2002")
		#expect(status.training.summary?.athleteName == "Bo Lind")
		#expect(try secrets.intervalsConnection() == replacement)
		#expect(fixture.ada.calls.allSatisfy { !$0.isWrite })
		#expect(peer.athleteB.calls.allSatisfy { !$0.isWrite })
	}

	private func open() async -> Coach {
		await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: fixture.records), secrets: secrets,
					models: .scripted(fixture.transport),
					training: .fake { credential, _ in peer.client(for: credential) },
					credits: .fake(FakeCreditsClient()), host: ImmediateExecutionHost(),
					clock: fixture.clock),
				builtInModel: testModel, displayLocale: testDisplayLocale, coalescing: quickWindow))
	}

	private func assertTurnUsesBo(_ coach: Coach) async throws {
		fixture.transport.respond = ScriptedReply.sequence(
			[
				.toolCall(name: ToolName.intervalsFetchAthlete.rawValue, arguments: "{}"),
				.finish(reason: .toolCalls), .text("Profile read."), .finish(reason: .stop),
			], otherwise: fixture.transport.respond)
		_ = try await coach.sendAndSettle("Read my training profile")
		let claims = try await fixture.records.fetch(
			RecordQuery(scope: .deviceLocal([.turnClaim]), chatId: "main"))
		#expect(claims.records.last?.account.athlete == "i2002")
		let request = try #require(fixture.transport.requests.last)
		let results = request.messages.filter { $0.role == .tool }.map(\.content).joined()
		#expect(results.contains("Bo Lind"))
		#expect(!results.contains("Ada Kovač"))
		#expect(peer.athleteB.profileReadCount >= 2)
	}
}

enum UnavailablePeerState: CaseIterable, Sendable {
	case deleted
	case rejected
	case unavailable
	case locked
	case revoked

	func matches(_ training: TrainingStatus) -> Bool {
		switch (self, training) {
		case (.deleted, .unconnected), (.locked, .unavailable(.secureStorageLocked)): true
		case (.rejected, .connected(let summary, _)), (.revoked, .connected(let summary, _)):
			summary.profile == .failed(.credentialRejected)
		case (.unavailable, .connected(let summary, _)):
			summary.profile == .failed(.temporarilyUnavailable)
		default: false
		}
	}
}

extension TrainingAccount {
	fileprivate var athlete: String? {
		guard case .intervals(_, let athlete) = self else { return nil }
		return athlete?.rawValue
	}
}

extension TrainingStatus {
	fileprivate var summary: IntervalsSummary? {
		guard case .connected(let summary, _) = self else { return nil }
		return summary
	}
}
