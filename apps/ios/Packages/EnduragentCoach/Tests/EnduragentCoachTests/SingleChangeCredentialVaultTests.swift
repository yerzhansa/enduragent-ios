import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test func differentAthleteWithBoundWorkIsRefused() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		_ = try await proposeRide(on: coach)
		let current = try #require(IntervalsAthleteID(rawValue: "i1001"))
		let new = try #require(IntervalsAthleteID(rawValue: "i2002"))
		#expect(
			await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
				== .refused(.differentAthlete(current: current, new: new)))
		#expect(try secrets.intervalsConnection() == testConnection)
		#expect(await coach.currentSnapshot(.main)?.review?.notice == nil)
		#expect(
			try await claimAccount(after: "Is Thursday on?", on: coach) == account(testConnection))
	}

	@Test func unverifiedAthleteResolvesOnTheNextReadAndThenRefusesAnotherAthlete() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		guard
			case .replaced(_, .unverifiable?) = await coach.changeTraining(
				.replace(apiKey: "icu-offline", athlete: .keyOwner))
		else {
			Issue.record("expected an unverifiable replacement")
			return
		}
		#expect(try secrets.intervalsConnection()?.resolvedAthlete == nil)
		offline.athlete = .cyclist(id: "i3003", name: "Nobody", ftp: 200)
		offline.restore(.profile)
		let status = try await coach.refreshedStatus()
		let resolved = try #require(try secrets.intervalsConnection())
		let athlete = try #require(IntervalsAthleteID(rawValue: "i3003"))
		#expect(resolved.resolvedAthlete == athlete)
		#expect(status.trainingAccount == account(resolved))
		_ = try await proposeRide(on: coach)
		let other = try #require(IntervalsAthleteID(rawValue: "i2002"))
		#expect(
			await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
				== .refused(.differentAthlete(current: athlete, new: other)))
		#expect(try secrets.intervalsConnection() == resolved)
	}

	@Test func confirmingAthleteSwitchFlips() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(pending.notice == nil)
		let outcome = await coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "other-athlete", athlete: .keyOwner))
		#expect(
			outcome
				== .replaced(
					IntervalsSummary(
						connectionID: try #require(try secrets.intervalsConnection()).id,
						keySuffix: "lete",
						profile: .available(
							IntervalsProfile(
								athleteID: try #require(IntervalsAthleteID(rawValue: "i2002")),
								name: "Bo Lind", wellness: .waiting))),
					authority: .changed))
		let active = try #require(try secrets.intervalsConnection())
		#expect(active.resolvedAthlete?.rawValue == "i2002")
		let status = try await coach.refreshedStatus()
		guard case .connected(let summary, let switched) = status.training else {
			Issue.record("expected a connected account, got \(status.training)")
			return
		}
		#expect(summary.athleteName == "Bo Lind")
		#expect(switched == account(active))
		let switchedReview = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(switchedReview.ref.review == pending.ref.review)
		#expect(switchedReview.notice?.kind == .accountChanged)
		#expect(switchedReview.controls == .none)
		let reopened = try #require(await self.coach(secrets).currentSnapshot(.main)?.review)
		#expect(reopened.ref.review == pending.ref.review)
		#expect(reopened.notice?.kind == .accountChanged)
		let proposals = try await records.fetch(
			RecordQuery(scope: .deviceLocal([.pendingProposal]), chatId: "main")
		).records
		#expect(proposals.map(\.account) == [account(testConnection)])
	}

	func proposeRide(on coach: Coach) async throws -> ReviewSnapshot {
		transport.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_workout",
					arguments:
						#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
				),
				.finish(reason: .toolCalls),
				.text("I've prepared the ride. Confirm to add it."),
				.finish(reason: .stop),
			], otherwise: transport.respond)
		_ = try await coach.sendAndSettle("Give me an endurance ride for tomorrow")
		return try #require(await coach.currentSnapshot(.main)?.review)
	}
}

extension CredentialVaultTests {
	@Test func unopenedPendingReviewBlocksAthleteSwitch() async throws {
		try await seed(
			records,
			[
				storedRecord(
					device: records.deviceId, wall: 1,
					body: .deviceLocal(
						.pendingProposal(
							sampleProposal(
								chatId: "unopened", nonce: Nonce(),
								expiresAt: clock.now.addingTimeInterval(600)))))
			])
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		#expect(await coach.mailboxes.isEmpty)
		try await expectAthleteSwitchRefused(on: coach, secrets: secrets)
		#expect(await coach.mailboxes.isEmpty)
	}
}

extension CredentialVaultTests {
	@Test func oldProposalCannotExecuteForTheNewAthlete() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = try await coach.refreshedStatus()
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		_ = await coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "other-athlete", athlete: .keyOwner))
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(await coach.currentSnapshot(.main)?.review?.notice?.kind == .accountChanged)
		let outcome = await coach.decide(.approve(token), in: .main)
		#expect(outcome == .blocked(.accountChanged))
		#expect(
			!bo.calls.contains { call in
				if case .createEvent = call { return true }
				return false
			})
	}

	@Test func sameAthleteRotationPreservesProposal() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let original = try #require(try secrets.intervalsConnection())
		_ = await coach.changeTraining(.replace(apiKey: "same-athlete-new-key", athlete: .keyOwner))
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.resolvedAthlete == testConnection.resolvedAthlete)
		#expect(current.id != testConnection.id)
		#expect(account(original).authority(under: account(current)) == .sameAthlete)
		try await expectStillApproved(token, on: coach)
	}

	@Test func resolvingTheSameConnectionPreservesProposal() async throws {
		let secrets = keyedSecrets()
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: testConnection.id, credential: testConnection.credential,
				selection: .keyOwner, resolvedAthlete: nil))
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		let original = try #require(try secrets.intervalsConnection())
		_ = try await coach.refreshedStatus()
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.id == testConnection.id)
		#expect(current.resolvedAthlete != nil)
		#expect(account(original).authority(under: account(current)) == .same)
		try await expectStillApproved(token, on: coach)
	}

	private func expectStillApproved(_ token: ReviewControlToken, on coach: Coach) async throws {
		#expect(await coach.currentSnapshot(.main)?.review?.token == token)
		#expect(
			await coach.decide(.approve(token), in: .main)
				== .completed([ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 1)))]))
		#expect(
			ada.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
	}

	@Test func unresolvedProposalCannotFollowAReplacementConnection() async throws {
		let secrets = keyedSecrets()
		_ = try await proposeRide(on: coach(secrets))
		let saved = try await records.fetch(RecordQuery(scope: .everyDeviceLocal))
		let restored = InMemoryRecordLog(deviceId: records.deviceId)
		let original = TrainingAccount.intervals(connection: testConnection.id, athlete: nil)
		try await restored.append(
			saved.records.map {
				AthleteRecord(
					ulid: $0.ulid, deviceId: $0.deviceId, hlc: $0.hlc, timeZone: $0.timeZone,
					civilDate: $0.civilDate, cause: $0.cause, account: original, body: $0.body)
			}, locality: .deviceLocal)
		let coach = await coach(secrets, log: restored)
		let pending = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = await coach.changeTraining(
			.replaceConfirmingAthleteSwitch(apiKey: "same-athlete-new-key", athlete: .keyOwner))
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.id != testConnection.id)
		#expect(current.resolvedAthlete == testConnection.resolvedAthlete)
		#expect(original.authority(under: account(current)) == .unverifiable)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(await coach.currentSnapshot(.main)?.review?.notice?.kind == .accountChanged)
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(.accountChanged))
		#expect(
			!ada.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
	}
}

extension CredentialVaultTests {
	@Test func unverifiableReplacementCannotExecuteOldWorkoutReview() async throws {
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		let pending = try await proposeRide(on: coach)
		#expect(await coach.decide(.presented(pending.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)
		_ = await coach.changeTraining(.replace(apiKey: "icu-offline", athlete: .keyOwner))
		#expect(try secrets.intervalsConnection()?.resolvedAthlete == nil)
		#expect(await coach.currentSnapshot(.main)?.review?.controls == ReviewControls.none)
		#expect(
			await coach.currentSnapshot(.main)?.review?.notice?.key == Catalog.reviewCannotVerify)
		#expect(await coach.decide(.approve(token), in: .main) == .blocked(.cannotVerify))
		#expect(
			!offline.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
	}
}

extension CredentialVaultTests {
	@Test func legacyProposalAppliesOnAnotherDevice() async throws {
		let legacy = Data(#"{"apiKey":{"_0":"icu-test-key"}}"#.utf8)
		let phoneBacking = legacyIntervalsBacking(legacy)
		let padBacking = legacyIntervalsBacking(legacy)
		let phone = ICloudKeychainStore(backing: phoneBacking)
		let pad = ICloudKeychainStore(backing: padBacking)
		let phoneConnection = try #require(try phone.intervalsConnection())
		let padConnection = try #require(try pad.intervalsConnection())
		#expect(phoneConnection.id == padConnection.id)
		let pending = try await proposeRide(on: coach(phone))
		let peer = await coach(pad)
		let review = try #require(await peer.currentSnapshot(.main)?.review)
		#expect(review.ref.review == pending.ref.review)
		#expect(await peer.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await peer.currentSnapshot(.main)?.review?.token)
		#expect(
			await peer.decide(.approve(token), in: .main)
				== .completed([ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 1)))]))
		#expect(
			ada.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
		for store in [phone, pad] {
			let resolved = try #require(try store.intervalsConnection())
			#expect(resolved.id == phoneConnection.id)
			#expect(resolved.credential == phoneConnection.credential)
			#expect(resolved.resolvedAthlete == testConnection.resolvedAthlete)
		}
	}
}

extension CredentialCorrectionTests {
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
		#expect(try secrets.openRouterAccountKey(at: .legacy) == "synthetic-router-key")
		#expect(try secrets.accessSelection() == .init(.credits))
	}
}
