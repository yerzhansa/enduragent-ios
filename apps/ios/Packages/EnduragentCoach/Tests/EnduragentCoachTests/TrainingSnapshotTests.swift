import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct TrainingSnapshotTests {
	let transport = FakeModelTransport()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
	let watchdog = HeldClock()

	@Test(arguments: 0..<4)
	func latestWellnessRowIsChosenByDateWhateverTheOrder(rotation: Int) throws {
		let rows: [WellnessDay] = [
			.on("1998-06-13"),
			.on("1998-06-09", [.fitness: 60]),
			.on("1998-06-12", [.weight: 25, .rampRate: 1.4]),
			.on("1998-06-10", [.restingHeartRate: 48, .sleepSeconds: 25_500]),
		]
		let rotated = Array(rows[rotation...] + rows[..<rotation])

		let snapshot = TrainingSnapshot(
			profile: nil, wellness: rotated,
			lookback: .snapshotLookback(endingOn: "1998-06-13"))

		guard case .available(let lines) = snapshot else {
			Issue.record("expected a wellness line, got \(snapshot)")
			return
		}
		#expect(lines.profile == nil)
		#expect(lines.wellness?.date == "1998-06-10")
		#expect(lines.wellness?.text == "Wellness 1998-06-10: resting HR 48 bpm · sleep 7h05")
	}

	@Test(arguments: [(-0.25, "-0.3"), (-0.75, "-0.8"), (-70.25, "-70.3")])
	func negativeValueOnATieRoundsAwayFromZeroLikeJavaScriptToFixed(value: Double, text: String) {
		let snapshot = TrainingSnapshot(
			profile: nil, wellness: [.on("1998-06-13", [.fitness: value])],
			lookback: .snapshotLookback(endingOn: "1998-06-13"))

		guard case .available(let lines) = snapshot else {
			Issue.record("expected a wellness line, got \(snapshot)")
			return
		}
		#expect(lines.wellness?.text == "Wellness 1998-06-13: Fitness \(text)")
	}

	@Test func turnPromptCarriesBothLinesAndLeavesAbsentFieldsOut() async throws {
		intervals.athlete = AthleteProfile(
			id: "i1001", name: "Ada", ftp: FTPReading(.number(250)),
			readings: Readings([.maxHeartRate: 188, .weight: 70]))
		intervals.wellness = [
			.on("1998-06-12", [.fitness: 50, .fatigue: 40]),
			.on("1998-06-13", [.fitness: 55.2, .fatigue: 42.1, .soreness: 0]),
		]
		let coach = try await coach()

		_ = try await coach.sendAndSettle("How is my form?")

		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(
			system.contains(
				"""
				# Athlete Profile & Latest Wellness

				Profile: FTP 250 W · max HR 188 bpm · weight 70 kg
				Wellness 1998-06-13: Fitness 55.2 · Fatigue 42.1 · Form +13.1 · soreness 0
				\(PromptStaticBlocks.snapshotGuidance)

				---
				"""))
		#expect(!system.contains(PromptStaticBlocks.snapshotFallback))
		#expect(coach.diagnostics.entries.isEmpty)
	}

	@Test func changedProfileReachesTheNextTurn() async throws {
		intervals.wellness = [.on("1998-06-13", [.fitness: 55.2, .fatigue: 42.1])]
		let coach = try await coach()
		_ = try await coach.sendAndSettle("How is my form?")
		intervals.athlete = intervals.athlete.with(ftp: FTPReading(.number(262)))

		_ = try await coach.sendAndSettle("And now?")

		let prompts = transport.requests.compactMap(\.messages.first?.content)
		#expect(prompts.count == 2)
		#expect(
			prompts.first?.contains("Profile: FTP 250 W\nWellness 1998-06-13: Fitness 55.2") == true
		)
		#expect(
			prompts.last?.contains("Profile: FTP 262 W\nWellness 1998-06-13: Fitness 55.2") == true)
	}

	@Test(arguments: [
		(FakeTrainingRead.profile, SnapshotLineKind.profile, "Wellness 1998-06-13: Fitness 55.2"),
		(.wellness, .wellness, "Profile: FTP 250 W"),
	])
	func oneFailedReadDropsOnlyItsOwnLine(
		read: FakeTrainingRead, kind: SnapshotLineKind, kept: String
	) async throws {
		intervals.wellness = [.on("1998-06-13", [.fitness: 55.2])]
		let coach = try await coach()
		intervals.fail(
			read,
			with: IntervalsError(code: "http", details: "private upstream detail", status: 503))

		let settled = try await coach.sendAndSettle("How is my form?")

		#expect(replyText(settled) == "Easy spin today.")
		let request = try #require(transport.requests.first)
		let system = try #require(request.messages.first?.content)
		#expect(
			system.contains(
				"# Athlete Profile & Latest Wellness\n\n\(kept)\n\(PromptStaticBlocks.snapshotGuidance)"
			))
		#expect(!system.contains(PromptStaticBlocks.snapshotFallback))
		#expect(!system.contains("private upstream detail"))
		#expect(
			coach.diagnostics.entries.map(\.event) == [
				.snapshotReadFailed(request.attempt, kind, .temporarilyUnavailable)
			])
	}

	@Test func bothReadsFailingGiveTheFallbackAndNoLines() async throws {
		intervals.wellness = [.on("1998-06-13", [.fitness: 55.2])]
		let coach = try await coach()
		let failure = IntervalsError(code: "http", details: "status 503", status: 503)
		intervals.fail(.profile, with: failure)
		intervals.fail(.wellness, with: failure)

		let settled = try await coach.sendAndSettle("How is my form?")

		#expect(replyText(settled) == "Easy spin today.")
		let request = try #require(transport.requests.first)
		let system = try #require(request.messages.first?.content)
		#expect(
			system.contains(PromptStaticBlocks.snapshotFallback + PromptAssembly.sectionSeparator))
		#expect(!system.contains("Profile:"))
		#expect(!system.contains("Wellness 1998"))
		#expect(
			coach.diagnostics.entries.map(\.event) == [
				.snapshotReadFailed(request.attempt, .profile, .temporarilyUnavailable),
				.snapshotReadFailed(request.attempt, .wellness, .temporarilyUnavailable),
			])
	}

	@Test func missedDeadlineCancelsBothReadsAndGivesTheFallback() async throws {
		intervals.wellness = [.on("1998-06-13", [.fitness: 55.2])]
		let coach = try await coach()
		let profile = intervals.hold(.profile)
		let wellness = intervals.hold(.wellness)

		let turn = try #require(
			try await coach.send(draft("How is my form?"), to: .main).acceptedTurn)
		try #require(try await entered(profile))
		try #require(try await entered(wellness))
		try await watchdog.waitUntilHeld(SnapshotPolicy.deadline)
		#expect(transport.requests.isEmpty)
		watchdog.release(SnapshotPolicy.deadline)
		let settled = try #require(
			await coach.settledState(of: turn, in: .main, within: .hangGuard))

		#expect(replyText(settled) == "Easy spin today.")
		let request = try #require(transport.requests.first)
		let system = try #require(request.messages.first?.content)
		#expect(
			system.contains(PromptStaticBlocks.snapshotFallback + PromptAssembly.sectionSeparator))
		#expect(!system.contains("Profile:"))
		#expect(!system.contains("Wellness 1998"))
		#expect(
			coach.diagnostics.entries.map(\.event) == [.snapshotDeadlineMissed(request.attempt)])
	}

	@Test func readFinishedBeforeAMissedDeadlineStillGivesNoLines() async throws {
		let reader = TrainingSnapshotReader(
			clock: clock, deadlineSleep: watchdog.sleep, diagnostics: DiagnosticsLog(clock: clock))
		let wellness = intervals.hold(.wellness)
		let connection = connection()

		let reading = Task {
			try await reader.snapshot(for: connection, attempt: AttemptID(ulid: fixedUlid(1)))
		}
		defer { reading.cancel() }
		try #require(try await entered(wellness))
		try await watchdog.waitUntilHeld(SnapshotPolicy.deadline)
		watchdog.release(SnapshotPolicy.deadline)

		let missed = try await beforeDeadline(within: .hangGuard, onTimeout: { reading.cancel() }) {
			try await reading.value
		}
		#expect(missed == .unavailable(.deadlineMissed))
		#expect(intervals.count(of: .profile) == 1)
	}

	@Test func implausibleFTPIsMarkedAndFollowedByTheQualitativeSentence() async throws {
		intervals.athlete = intervals.athlete.with(ftp: .implausible(reported: 2500))
		let coach = try await coach()

		_ = try await coach.sendAndSettle("What should my intervals be?")

		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(
			system.contains(
				"""
				Profile: FTP 2500 W (not usable)
				\(PromptStaticBlocks.snapshotGuidance)
				The profile's FTP is not a usable number (it must be between 50 and 600 W). \
				Keep intensity guidance qualitative, do not work out zones or watt targets from it, \
				and ask the athlete to check their FTP in intervals.icu.

				---
				"""))
	}

	@Test(arguments: [FTPReading.absent, FTPReading(.number(250))])
	func usableOrAbsentFTPAddsNoSentence(ftp: FTPReading) async throws {
		intervals.athlete = AthleteProfile(
			id: "i1001", name: "Ada", ftp: ftp, readings: Readings([.lthr: 165]))
		let coach = try await coach()

		_ = try await coach.sendAndSettle("What should my intervals be?")

		let system = try #require(transport.requests.first?.messages.first?.content)
		#expect(system.contains("LTHR 165 bpm\n" + PromptStaticBlocks.snapshotGuidance + "\n\n---"))
		#expect(!system.contains("not a usable number"))
	}

	@Test func unconnectedTurnMakesNoReadAndRecordsNoFailure() async throws {
		let secrets = ICloudKeychainStore(backing: FixtureSecretStoreBacking())
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
		let coach = try await coach(secrets: secrets)

		_ = try await coach.sendAndSettle("How is my form?")

		#expect(transport.requests.count == 1)
		#expect(intervals.count(of: .profile) == 0)
		#expect(intervals.count(of: .wellness) == 0)
		#expect(coach.diagnostics.entries.isEmpty)
	}

	@Test(arguments: [FakeTrainingRead.profile, .wellness])
	func cancelledReadEndsTheSnapshotWithoutADiagnostic(read: FakeTrainingRead) async throws {
		intervals.fail(read, with: CancellationError())
		let diagnostics = DiagnosticsLog(clock: clock)
		let reader = TrainingSnapshotReader(
			clock: clock, deadlineSleep: watchdog.sleep, diagnostics: diagnostics)
		let connection = connection()

		await #expect(throws: CancellationError.self) {
			try await reader.snapshot(for: connection, attempt: AttemptID(ulid: fixedUlid(1)))
		}
		#expect(diagnostics.entries.isEmpty)
	}

	@Test(arguments: [
		(401, TrainingFailure.credentialRejected), (403, .credentialRejected),
		(422, .requestRejected), (503, .temporarilyUnavailable),
	])
	func diagnosticKeepsTheFailureClassification(status: Int, failure: TrainingFailure)
		async throws
	{
		intervals.fail(
			.wellness,
			with: IntervalsError(code: "failed", details: "private upstream detail", status: status)
		)
		let diagnostics = DiagnosticsLog(clock: clock)
		let reader = TrainingSnapshotReader(
			clock: clock, deadlineSleep: watchdog.sleep, diagnostics: diagnostics)
		let attempt = AttemptID(ulid: fixedUlid(1))

		_ = try await reader.snapshot(for: connection(), attempt: attempt)

		#expect(
			diagnostics.entries.map(\.event) == [.snapshotReadFailed(attempt, .wellness, failure)])
	}

	func coach(secrets: any SecretStore = keyedSecrets()) async throws -> Coach {
		let reply: [ScriptedEvent] = [.text("Easy spin today."), .finish(reason: .stop)]
		transport.respond = ScriptedReply.sequence(
			reply + reply, for: .chat, otherwise: transport.respond)
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: InMemoryRecordLog(), clock: clock,
			secrets: secrets, watchdogClock: watchdog)
		_ = try await coach.vault.trainingConnection()
		return coach
	}

	func entered(_ gate: FakeIntervalsReadGate) async throws -> Bool {
		try await beforeDeadline(within: .hangGuard) { await gate.waitUntilEntered() } != nil
	}

	func connection() -> TrainingConnection {
		connectedTraining(intervals)
	}
}
