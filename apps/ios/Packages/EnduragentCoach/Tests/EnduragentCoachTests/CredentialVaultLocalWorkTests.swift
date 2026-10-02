import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension CredentialVaultTests {
	@Test(arguments: [false, true])
	func remoteOnlyTurnDoesNotBlockAthleteSwitch(opened: Bool) async throws {
		try await seed(
			records,
			[
				storedRecord(
					device: DeviceID(rawValue: "other-phone"), wall: 1,
					body: .synced(sampleUser(chatId: .main, text: "Thursday?")))
			])
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		if opened {
			#expect(
				await coach.currentSnapshot(.main)?.turns.first?.state == .accepted(.onOtherDevice))
		}
		try await expectAthleteSwitch(on: coach, secrets: secrets)
	}

	@Test(arguments: [false, true])
	func beforeUpgradeQuestionDoesNotBlockAthleteSwitch(opened: Bool) async throws {
		try await seed(
			records,
			[
				storedRecord(
					device: records.deviceId, wall: 1,
					body: legacyUser(chatId: .main, text: "Thursday?"))
			])
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		if opened {
			#expect(
				await coach.currentSnapshot(.main)?.turns.first?.state == .accepted(.beforeUpgrade))
		}
		try await expectAthleteSwitch(on: coach, secrets: secrets)
	}

	@Test func unopenedLocalTurnBlocksAthleteSwitch() async throws {
		try await seedLocalQuestion()
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		#expect(await coach.mailboxes.isEmpty)
		try await expectAthleteSwitchRefused(on: coach, secrets: secrets)
		#expect(await coach.mailboxes.isEmpty)
	}

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

	@Test(arguments: [false, true])
	func unresolvedLocalClaimBlocksAthleteSwitch(opened: Bool) async throws {
		try await seedLocalQuestion(claimed: true)
		let faulty = FaultInjectingRecordLog(wrapping: records)
		faulty.failRecoveryReads = true
		let secrets = keyedSecrets()
		let coach = await coach(secrets, log: faulty)
		if opened {
			let state = try #require(await coach.currentSnapshot(.main)?.turns.first?.state)
			guard case .unrecovered = state else {
				Issue.record("expected an unresolved claim, got \(state)")
				return
			}
		}
		try await expectAthleteSwitchRefused(on: coach, secrets: secrets)
	}

	@Test(arguments: [false, true])
	func pendingFlushBlocksAthleteSwitch(opened: Bool) async throws {
		let turn = TurnID(ulid: fixedUlid(1))
		try await seed(
			records,
			[
				storedRecord(
					device: records.deviceId, wall: 1, ulid: fixedUlid(1),
					body: .synced(sampleUser(chatId: .main, text: "Thursday?", turn: turn))),
				storedRecord(
					device: records.deviceId, wall: 2, ulid: fixedUlid(2),
					body: .synced(sampleReply(chatId: .main, turn: turn, text: "Rest."))),
				storedRecord(
					device: records.deviceId, wall: 3, ulid: fixedUlid(3),
					body: .deviceLocal(
						.flushPending(
							FlushPendingBody(
								chatId: .main, messageUlids: [fixedUlid(1), fixedUlid(2)],
								process: ProcessID(ulid: fixedUlid(4)))))),
			])
		let faulty = FaultInjectingRecordLog(wrapping: records)
		faulty.failRecoveryReads = true
		let secrets = keyedSecrets()
		let coach = await coach(secrets, log: faulty)
		if opened { _ = await coach.currentSnapshot(.main) }
		try await expectAthleteSwitchRefused(on: coach, secrets: secrets)
	}

	@Test func openedLocalTurnBlocksAthleteSwitch() async throws {
		try await seedLocalQuestion()
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		#expect(
			await coach.currentSnapshot(.main)?.turns.first?.state == .accepted(.awaitingRestart))
		try await expectAthleteSwitchRefused(on: coach, secrets: secrets)
	}

	@Test func recoveredLocalClaimDoesNotBlockAthleteSwitch() async throws {
		try await seedLocalQuestion(claimed: true)
		let secrets = keyedSecrets()
		let coach = await coach(secrets)
		await coach.lifecycle(.becameActive)
		try await expectAthleteSwitch(on: coach, secrets: secrets)
	}

	@Test(arguments: [false, true])
	func unreadableLedgerBlocksAthleteSwitch(opened: Bool) async throws {
		let faulty = FaultInjectingRecordLog(wrapping: records)
		let secrets = keyedSecrets()
		let coach = await coach(secrets, log: faulty)
		if opened { _ = await coach.currentSnapshot(.main) }
		faulty.failFetches = true
		try await expectAthleteSwitchRefused(on: coach, secrets: secrets)
	}

	private func seedLocalQuestion(claimed: Bool = false) async throws {
		let turn = TurnID(ulid: fixedUlid(1))
		var rows = [
			storedRecord(
				device: records.deviceId, wall: 1,
				body: .synced(sampleUser(chatId: .main, text: "Thursday?", turn: turn)))
		]
		if claimed {
			rows.append(
				storedRecord(
					device: records.deviceId, wall: 2,
					body: .deviceLocal(
						.turnClaim(
							TurnClaimBody(
								chatId: .main, turn: turn, attempt: AttemptID(ulid: fixedUlid(2)),
								process: ProcessID(ulid: fixedUlid(3)), lease: .continuedProcessing)
						))))
		}
		try await seed(records, rows)
	}

	private func expectAthleteSwitch(on coach: Coach, secrets: any SecretStore) async throws {
		let outcome = await coach.changeTraining(
			.replace(apiKey: "other-athlete", athlete: .keyOwner))
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
		#expect(active.credential == .apiKey("other-athlete"))
		#expect(active.resolvedAthlete?.rawValue == "i2002")
		#expect(active.id != testConnection.id)
	}

	private func expectAthleteSwitchRefused(on coach: Coach, secrets: any SecretStore) async throws
	{
		let current = try #require(IntervalsAthleteID(rawValue: "i1001"))
		let new = try #require(IntervalsAthleteID(rawValue: "i2002"))
		#expect(
			await coach.changeTraining(.replace(apiKey: "other-athlete", athlete: .keyOwner))
				== .refused(.differentAthlete(current: current, new: new)))
		#expect(try secrets.intervalsConnection() == testConnection)
	}
}
