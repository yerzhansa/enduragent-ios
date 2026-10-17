import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

extension SyncedTrainingIdentityTests {
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
			fixture.ada.fail(
				.profile,
				with: IntervalsError(code: "http", details: "Revoked fixture key", status: 401))
		}
		let block: ReviewBlock = state == .deleted ? .accountChanged : .cannotVerify
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(block))
		let retained = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(retained.ref.review == review.ref.review)
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
		#expect(fixture.ada.count(of: .profile) >= 2)
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .completed([ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 1)))]))
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
		#expect(await coach.currentSnapshot(.main)?.review?.ref.review == review.ref.review)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		try await assertTurnUsesBo(coach)
		let status = try await coach.observedStatus()
		#expect(status.trainingAccount?.athlete == "i2002")
		#expect(status.training.summary?.athleteName == "Bo Lind")
		#expect(try secrets.intervalsConnection() == replacement)
		#expect(fixture.ada.calls.allSatisfy { !$0.isWrite })
		#expect(peer.athleteB.calls.allSatisfy { !$0.isWrite })
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

extension SwiftDataSuites.AthleteOwnershipSnapshotTests {
	@Test func pendingReviewRetainsItsSavedAthlete() async throws {
		let fixture = try AthleteScopedCoachingFixture(store: InMemoryRecordLog())
		let coach = await fixture.open()
		fixture.transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_workout",
					arguments:
						#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
				),
				.finish(reason: .toolCalls), .text("Review ready."), .finish(reason: .stop),
			], otherwise: fixture.transport.respond)
		_ = try await coach.sendAndSettle("Prepare an endurance ride")
		let snapshots = await coach.observe(.main)
		let before = try #require(
			try await firstSnapshot(in: snapshots, within: .hangGuard) {
				$0.review != nil
			}?.review)
		#expect(before.attribution.ownership == .verified(try #require(athleteA)))
		#expect(await coach.decide(.presented(before.ref), in: .main) == .presentationRecorded)
		try fixture.peer.replace(.athleteB)
		await coach.lifecycle(.becameActive)
		let blocked = try #require(
			try await firstSnapshot(in: snapshots, within: .hangGuard) {
				$0.review?.notice?.kind == .accountChanged
			}?.review)
		#expect(blocked.attribution.ownership == before.attribution.ownership)
		#expect(blocked.controls == .none)
		#expect(blocked.notice?.key == Catalog.reviewAccountChanged)
		#expect(blocked.cards == before.cards)
		await coach.lifecycle(.willTerminate)
		let after = await fixture.open()
		await after.lifecycle(.becameActive)
		let reopened = try #require(
			try await firstSnapshot(in: await after.observe(.main), within: .hangGuard) {
				$0.review?.notice?.kind == .accountChanged
			}?.review)
		#expect(reopened.attribution == blocked.attribution)
		#expect(reopened.controls == .none)
		#expect(fixture.peer.athleteA.events.isEmpty && fixture.peer.athleteB.events.isEmpty)
		await after.lifecycle(.willTerminate)
	}
}
