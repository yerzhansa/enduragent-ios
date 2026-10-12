import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(2))) struct ReconnectReviewRecoveryTests {
		let directory: URL
		let fixture: AthleteScopedCoachingFixture
		let proposals = DurableCalendarWriteTests()
		let confirmed = ReviewOutcome.applied([
			ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))
		])

		init() throws {
			directory = try TestTemporaryFolders.make()
			fixture = try AthleteScopedCoachingFixture(
				store: makeSwiftDataLog(
					deviceId: DeviceID(rawValue: "reconnect-review-phone"), directory: directory))
		}

		@Test func peerApprovalRequiresANewBApproval() async throws {
			let coach = await fixture.open()
			let (_, old) = try await proposals.proposal(on: coach, model: fixture.transport)
			await coach.stop(.main)
			try fixture.peer.replace(.athleteB)
			#expect(await coach.decide(.approve(old), in: .main) == .blocked(.accountChanged))
			let blocked = try #require(await coach.currentSnapshot(.main)?.review)
			#expect(blocked.ref.set == old.ref.set)
			#expect(blocked.controls == .none)
			#expect(blocked.notice?.key == Catalog.reviewAccountChanged)
			let notice = try #require(blocked.notice)
			#expect(
				CatalogPhrasebook(tag: .en).say(notice.key, notice.vars)
					== "This workout was prepared for a different intervals.icu athlete. Ask me again to prepare it for the connected athlete."
			)
			#expect(fixture.peer.athleteA.calls.allSatisfy { !$0.isWrite })
			#expect(fixture.peer.athleteB.calls.allSatisfy { !$0.isWrite })
			let (_, fresh) = try await proposals.proposal(
				on: coach, model: fixture.transport, name: "B's fresh workout")
			#expect(fresh.ref.set != old.ref.set)
			#expect(await coach.decide(.approve(old), in: .main) == .staleControl)
			#expect(fixture.peer.athleteB.events.isEmpty)
			#expect(await coach.decide(.approve(fresh), in: .main) == confirmed)
			#expect(fixture.peer.athleteA.events.isEmpty)
			#expect(fixture.peer.athleteB.events.map(\.name) == ["B's fresh workout"])
			#expect(fixture.peer.athleteB.calls.filter(\.isWrite).count == 1)
			await coach.lifecycle(.willTerminate)
		}

		@Test func peerRotationReopensReviewAndAInformation() async throws {
			let information = try await fixture.seedInformation(
				"A", account: fixture.accountA, offset: 100)
			let coach = await fixture.open()
			let (_, token) = try await proposals.proposal(on: coach, model: fixture.transport)
			await coach.stop(.main)
			let original = try await fixture.store.fetch(
				RecordQuery(scope: .deviceLocal([.pendingProposal]))
			).records
			await coach.lifecycle(.willTerminate)
			try fixture.peer.replace(.rotatedA)
			let reads = fixture.peer.athleteA.profileReadCount
			let reopened = try await reopen()
			await reopened.lifecycle(.becameActive)
			let retained = try #require(await reopened.currentSnapshot(.main)?.review)
			#expect(retained.ref.set == token.ref.set)
			#expect(
				retained.attribution.ownership
					== .verified(try #require(testConnection.resolvedAthlete)))
			#expect(retained.notice == nil)
			let request = try await fixture.read(using: reopened)
			try fixture.assertInformation("A", excluding: "B_", in: request)
			#expect(
				await reopened.decide(.presented(retained.ref), in: .main) == .presentationRecorded)
			let approval = try #require(await reopened.currentSnapshot(.main)?.review?.token)
			#expect(fixture.peer.athleteA.profileReadCount > reads)
			let beforeApproval = fixture.peer.athleteA.profileReadCount
			#expect(await reopened.decide(.approve(approval), in: .main) == confirmed)
			#expect(fixture.peer.athleteA.profileReadCount > beforeApproval)
			#expect(fixture.peer.athleteA.events.map(\.name) == ["Strength"])
			#expect(fixture.peer.athleteA.calls.filter(\.isWrite).count == 1)
			#expect(fixture.peer.athleteB.calls.allSatisfy { !$0.isWrite })
			let saved = try await fixture.store.fetch(
				RecordQuery(scope: .deviceLocal([.pendingProposal]))
			).records
			#expect(saved == original)
			let synced = try await fixture.store.fetch(RecordQuery(scope: .everySynced)).records
			#expect(information.allSatisfy { synced.contains($0) })
			await reopened.lifecycle(.willTerminate)
		}

		@Test func unknownSaveReopensUnderBAndReconcilesOnlyAfterReturningToA() async throws {
			let coach = await fixture.open()
			let pending = try await unknownSave(on: coach)
			let original = try await fixture.store.fetch(
				RecordQuery(scope: .synced([.reviewWrite]))
			).records
			let connection = try fixture.secrets.intervalsConnection()
			#expect(
				await coach.changeTraining(
					.replace(apiKey: FixtureTrainingPeer.Key.athleteB.secret, athlete: .keyOwner))
					== .refused(
						.differentAthlete(
							current: try #require(IntervalsAthleteID(rawValue: "i1001")),
							new: try #require(IntervalsAthleteID(rawValue: "i2002")))))
			#expect(try fixture.secrets.intervalsConnection() == connection)
			await coach.lifecycle(.willTerminate)
			try fixture.peer.replace(.athleteB)
			let reopened = try await reopen()
			await reopened.lifecycle(.becameActive)
			let blocked = try #require(await reopened.currentSnapshot(.main)?.review)
			#expect(blocked.ref.set == pending.ref.set)
			#expect(
				blocked.attribution.ownership
					== .verified(try #require(testConnection.resolvedAthlete)))
			guard case .cancelOnly = blocked.controls else {
				Issue.record("A's unknown save must offer only Cancel under B")
				return
			}
			let aCalls = fixture.peer.athleteA.calls
			let bCalls = fixture.peer.athleteB.calls
			let aReads = fixture.peer.athleteA.profileReadCount
			let bReads = fixture.peer.athleteB.profileReadCount
			#expect(
				await reopened.decide(.checkAgain(blocked.ref), in: .main)
					== .blocked(.accountChanged))
			#expect(fixture.peer.athleteA.calls == aCalls)
			#expect(fixture.peer.athleteB.calls == bCalls)
			#expect(fixture.peer.athleteA.profileReadCount == aReads)
			#expect(fixture.peer.athleteB.profileReadCount == bReads)
			let afterB = try await fixture.store.fetch(
				RecordQuery(scope: .synced([.reviewWrite]))
			).records
			#expect(afterB == original)
			guard
				case .replaced = await reopened.changeTraining(
					.replaceConfirmingAthleteSwitch(
						apiKey: FixtureTrainingPeer.Key.athleteA.secret, athlete: .keyOwner))
			else {
				Issue.record("Reconnecting A must keep the unknown operation recoverable")
				return
			}
			let recovery = try #require(await reopened.currentSnapshot(.main)?.review)
			#expect(recovery.controls == .checkAgain(recovery.ref))
			let aBeforeRead = fixture.peer.athleteA.calls
			let bBeforeRead = fixture.peer.athleteB.calls
			#expect(await reopened.decide(.checkAgain(recovery.ref), in: .main) == confirmed)
			#expect(
				Array(fixture.peer.athleteA.calls.dropFirst(aBeforeRead.count))
					== [.events(oldest: "1998-06-14", newest: "1998-06-14")])
			#expect(fixture.peer.athleteB.calls == bBeforeRead)
			#expect(fixture.peer.athleteA.events.count == 1)
			#expect(fixture.peer.athleteA.calls.filter(\.isWrite).count == 1)
			#expect(fixture.peer.athleteB.events.isEmpty)
			#expect(await reopened.currentSnapshot(.main)?.review == nil)
			let writes = try await fixture.store.fetch(
				RecordQuery(scope: .synced([.reviewWrite]))
			).records
			#expect(writes.allSatisfy { $0.account == fixture.accountA })
			#expect(await reopened.currentSnapshot(.main)?.notes.values.flatMap { $0 }.count == 1)
			await reopened.lifecycle(.willTerminate)
		}

		@Test func checkAgainRetriesAfterTransientIdentityFailure() async throws {
			let coach = await fixture.open()
			let pending = try await unknownSave(on: coach)
			let aCalls = fixture.peer.athleteA.calls
			let bCalls = fixture.peer.athleteB.calls
			let bReads = fixture.peer.athleteB.profileReadCount
			fixture.peer.athleteA.setProfileOutcome(.failure(URLError(.notConnectedToInternet)))
			let failed = await coach.decide(.checkAgain(pending.ref), in: .main)
			#expect(failed.notice?.key == Catalog.reviewWriteReadFailed)
			let retry = try #require(await coach.currentSnapshot(.main)?.review)
			#expect(retry.controls == .checkAgain(retry.ref))
			#expect(retry.notice?.key == Catalog.reviewWriteReadFailed)
			#expect(fixture.peer.athleteA.calls == aCalls)
			#expect(fixture.peer.athleteB.calls == bCalls)
			fixture.peer.athleteA.setProfileOutcome(
				.success(AthleteProfile(id: "i1001", name: "Fixture A", ftp: 220)))
			let reads = fixture.peer.athleteA.profileReadCount
			#expect(await coach.decide(.checkAgain(retry.ref), in: .main) == confirmed)
			#expect(fixture.peer.athleteA.profileReadCount > reads)
			#expect(
				Array(fixture.peer.athleteA.calls.dropFirst(aCalls.count))
					== [.events(oldest: "1998-06-14", newest: "1998-06-14")])
			#expect(fixture.peer.athleteA.events.count == 1)
			#expect(fixture.peer.athleteA.calls.filter(\.isWrite).count == 1)
			#expect(fixture.peer.athleteB.calls == bCalls)
			#expect(fixture.peer.athleteB.profileReadCount == bReads)
			#expect(await coach.currentSnapshot(.main)?.review == nil)
			await coach.lifecycle(.willTerminate)
		}

		@Test(arguments: [false, true])
		func cancelUnderBReleasesImmediatelyWithoutRequests(offline: Bool) async throws {
			let coach = await fixture.open()
			_ = try await unknownSave(on: coach)
			await coach.lifecycle(.willTerminate)
			try fixture.peer.replace(.athleteB)
			let reopened = try await reopen()
			await reopened.lifecycle(.becameActive)
			let pending = try #require(await reopened.currentSnapshot(.main)?.review)
			guard case .cancelOnly(let token) = pending.controls else {
				Issue.record("A's unknown save must offer only Cancel under B")
				return
			}
			if offline {
				for client in [fixture.peer.athleteA, fixture.peer.athleteB] {
					client.failCalendarReadOnce = true
					client.writeFailure = URLError(.notConnectedToInternet)
					client.setProfileOutcome(.failure(URLError(.notConnectedToInternet)))
				}
			}
			let aCalls = fixture.peer.athleteA.calls
			let bCalls = fixture.peer.athleteB.calls
			let aReads = fixture.peer.athleteA.profileReadCount
			let bReads = fixture.peer.athleteB.profileReadCount
			#expect(await reopened.decide(.cancel(token), in: .main) == .canceled(kept: []))
			#expect(fixture.peer.athleteA.calls == aCalls)
			#expect(fixture.peer.athleteB.calls == bCalls)
			#expect(fixture.peer.athleteA.profileReadCount == aReads)
			#expect(fixture.peer.athleteB.profileReadCount == bReads)
			try await assertClosedNote(on: reopened)
			#expect(await reopened.decide(.checkAgain(token.ref), in: .main) == .staleControl)
			#expect(await reopened.decide(.approve(token), in: .main) == .staleControl)
			#expect(await reopened.decide(.retryRemaining(token), in: .main) == .staleControl)
			let cancellation = try await fixture.store.fetch(
				RecordQuery(scope: .synced([.reviewCancelledUnknown]))
			).records
			#expect(cancellation.count == 1)
			#expect(cancellation.first?.account == fixture.accountA)
			fixture.peer.athleteB.setProfileOutcome(
				.success(AthleteProfile(id: "i2002", name: "Bo Lind", ftp: 240)))
			let (_, fresh) = try await proposals.proposal(
				on: reopened, model: fixture.transport, name: "B after Cancel")
			#expect(fresh.ref.set != token.ref.set)
			#expect(await reopened.decide(.cancel(fresh), in: .main) == .canceled(kept: []))
			await reopened.lifecycle(.willTerminate)
			let after = try await reopen()
			await after.lifecycle(.becameActive)
			try await assertClosedNote(on: after)
			#expect(fixture.peer.athleteA.events.count == 1)
			#expect(fixture.peer.athleteB.events.isEmpty)
			await after.lifecycle(.willTerminate)
		}

		private func unknownSave(on coach: Coach) async throws -> ReviewSnapshot {
			fixture.peer.athleteA.loseCalendarSaveAnswerOnce = true
			let (_, token) = try await proposals.proposal(on: coach, model: fixture.transport)
			let outcome = await coach.decide(.approve(token), in: .main)
			#expect(outcome.notice?.key == Catalog.reviewWritePending)
			await coach.stop(.main)
			let pending = try #require(await coach.currentSnapshot(.main)?.review)
			#expect(pending.controls == .checkAgain(pending.ref))
			#expect(fixture.peer.athleteA.events.count == 1)
			return pending
		}

		private func reopen() async throws -> Coach {
			await fixture.open(
				store: try makeSwiftDataLog(deviceId: fixture.store.deviceId, directory: directory))
		}

		private func assertClosedNote(on coach: Coach) async throws {
			let snapshot = try #require(await coach.currentSnapshot(.main))
			#expect(snapshot.review == nil)
			#expect(
				snapshot.notes.values.flatMap { $0 }.map {
					$0.sentence(in: testDisplayLocale(.automatic))
				}
					== [CancelUnknownSaveTests.sentence])
		}
	}
}
