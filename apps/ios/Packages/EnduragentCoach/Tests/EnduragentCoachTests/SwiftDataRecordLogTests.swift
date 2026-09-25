import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SwiftDataRecordLogTests {
	let phoneA = DeviceID(rawValue: "phone-a")
	let phoneB = DeviceID(rawValue: "phone-b")
	let expires = Date(timeIntervalSince1970: 899_164_800)

	@Test func appendRoutesByLocality() async throws {
		let log = try makeSwiftDataLog(deviceId: phoneA)
		try await seed(
			log,
			[
				storedRecord(
					device: phoneA, wall: 1,
					body: .synced(sampleUser(chatId: .main, text: "synced"))),
				storedRecord(
					device: phoneA, wall: 2,
					body: .deviceLocal(
						.pendingProposal(
							sampleProposal(chatId: .main, nonce: Nonce(), expiresAt: expires)))),
			]
		)
		let synced = try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		let local = try await log.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal])))
			.records
		#expect(kinds(synced) == ["userMessage"])
		#expect(kinds(local) == ["pendingProposal"])
		let legacy = try await log.fetch(
			RecordQuery(scope: .synced([], includeLegacy: [.assistantMessage]))
		).records
		#expect(legacy.isEmpty)
	}

	@Test func batchAppendIsAllOrNothing() async throws {
		let log = try makeSwiftDataLog(deviceId: phoneA)
		let good = storedRecord(
			device: phoneA, wall: 1, body: .synced(sampleUser(chatId: .main, text: "kept")))
		let unencodable = storedRecord(
			device: phoneA, wall: 2, body: legacyUser(chatId: .main, text: "read-only"))
		await #expect(throws: RecordDecodeFailure.self) {
			try await log.append([good, unencodable], locality: .synced)
		}
		let stored = try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(stored.isEmpty)
	}

	@Test func fetchSyncedIsUnionAndLocalIsThisDevice() async throws {
		let log = try makeSwiftDataLog(deviceId: phoneA)
		try await seed(
			log,
			[
				storedRecord(
					device: phoneB, wall: 1,
					body: .synced(sampleUser(chatId: .main, text: "from b"))),
				storedRecord(
					device: phoneA, wall: 2,
					body: .synced(sampleUser(chatId: .main, text: "from a"))),
				storedRecord(
					device: phoneA, wall: 3,
					body: .deviceLocal(
						.pendingProposal(
							sampleProposal(chatId: .main, nonce: Nonce(), expiresAt: expires)))),
			]
		)
		let synced = try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(Set(synced.map(\.deviceId)) == [phoneA, phoneB])
		let local = try await log.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal])))
			.records
		#expect(local.map(\.deviceId) == [phoneA])
	}

	@Test func envelopeRoundTripsCauseAndAccount() async throws {
		let log = try makeSwiftDataLog(deviceId: phoneA)
		let connection = ConnectionID()
		let athlete = try #require(IntervalsAthleteID(rawValue: "i12345"))
		let stamp = testStamp(
			operation: .workoutChangeSet(
				ChangeSetID(ulid: ULID.generate(at: expires)), ChangeSetRevision(rawValue: 3)),
			account: .intervals(connection: connection, athlete: athlete)
		)
		let ledger = Ledger(
			log: log,
			clock: FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"))
		let written = try await ledger.commit(
			synced: [sampleUser(chatId: .main, text: "stamped")], stamp: stamp)
		let read = try await log.fetch(RecordQuery(scope: .synced([.userMessage]))).records
		#expect(read == written)
		#expect(read.first?.cause == .operation(stamp.operation, stamp.attempt))
		#expect(read.first?.account == .intervals(connection: connection, athlete: athlete))
	}

	@Test func bodyRoundTripForEveryKind() async throws {
		let log = try makeSwiftDataLog(deviceId: phoneA)
		let samples = try sampleBodies()
		let everyKind = Set(SyncedKind.allCases.map(\.rawValue))
			.union(DeviceLocalKind.allCases.map(\.rawValue))
		#expect(Set(samples.map(\.kind)) == everyKind)
		for (index, sample) in samples.enumerated() {
			try await log.append(
				[storedRecord(device: phoneA, wall: Int64(index + 1), body: sample.body)],
				locality: sample.body.locality
			)
		}
		let synced = try await log.fetch(RecordQuery(scope: .everySynced)).records
		let local = try await log.fetch(RecordQuery(scope: .everyDeviceLocal)).records
		let fetched = Dictionary(
			uniqueKeysWithValues: (synced + local).map { ($0.body.kind, $0.body) })
		for sample in samples {
			#expect(fetched[sample.kind] == sample.body)
		}
	}

	@Test func appendThousandRowsThenFetchOneChat() async throws {
		let log = try makeSwiftDataLog(deviceId: phoneA)
		let otherChat = try #require(ChatID(rawValue: "other"))
		var batch: [AthleteRecord] = []
		for index in 0..<1000 {
			let chat: ChatID = index % 10 == 0 ? .main : otherChat
			batch.append(
				storedRecord(
					device: phoneA, wall: Int64(index + 1),
					body: .synced(sampleUser(chatId: chat, text: "row \(index)"))))
		}
		try await log.append(batch, locality: .synced)
		let clock = ContinuousClock()
		let start = clock.now
		let page = try await log.fetch(
			RecordQuery(scope: .synced([.userMessage]), chatId: .main))
		let elapsed = clock.now - start
		#expect(page.records.count == 100)
		#expect(elapsed < .seconds(2))
	}

	private func sampleBodies() throws -> [(kind: String, body: RecordBody)] {
		let ulid = ULID.generate(at: Date(timeIntervalSince1970: 899_164_800))
		let turn = TurnID(ulid: ulid)
		let workout = IntervalsWorkoutInput(
			name: "Z2",
			steps: [
				.simple(
					SimpleStep(
						type: .warmup,
						duration: DurationInput(value: 10, unit: .minutes),
						power: PowerTarget(kind: .percentFtp, value: 55, low: nil, high: nil),
						cadence: CadenceTarget(value: 90, low: nil, high: nil),
						label: "wu"
					)
				),
				.set(
					SetStep(
						repeatCount: 3,
						interval: SimpleStep(
							type: .interval,
							duration: DurationInput(value: 30, unit: .seconds),
							power: PowerTarget(kind: .watts, value: 200, low: nil, high: nil),
							cadence: nil,
							label: nil
						),
						recovery: SimpleStep(
							type: .rest,
							duration: DurationInput(value: 15, unit: .seconds),
							power: nil,
							cadence: nil,
							label: nil
						)
					)
				),
			]
		)
		let nonce = Nonce(
			rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
		let synced: [SyncedRecordBody] = [
			.userMessage(
				UserMessageBody(
					chatId: .main, turn: turn, fragment: 0, draft: DraftID(), athleteText: "hi",
					slash: .review)),
			.turnSettled(
				TurnSettledBody(
					chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid),
					settlement: .replied(
						.model("hello"),
						lineage: ReplyLineage(templateHash: "t", assembledHash: "a")))),
			.windowStart(
				WindowStartBody(
					chatId: .main, firstIncludedUlid: ulid,
					reason: .reset(.explicit(ResetID(ulid: ulid))))),
			.compactionSummary(CompactionSummaryBody(chatId: .main, markdown: "sum")),
			.memorySection(MemorySectionBody(name: .person, content: "Ada")),
			.dailyNote(DailyNoteBody(note: "note")),
			.ledgerEvent(
				LedgerEventBody(
					date: "1998-06-10", kind: .decision, text: "Keep Saturdays free.", source: .chat
				)),
			.journal(JournalBody(op: .writeSection, preview: "person")),
			.provenance(
				ProvenanceBody(
					key: "k", garmin: true, nonGarmin: false, unknown: false, contentSha256: "abc")),
			.coachReplyLanguage(CoachReplyLanguageBody(tag: .it)),
			.planningDevice(
				PlanningDeviceBody(planningDeviceId: phoneA, planUlid: ulid, activatedAt: expires)),
		]
		let local: [DeviceLocalRecordBody] = [
			.pendingProposal(
				ProposalBody(
					chatId: .main,
					nonce: nonce,
					tool: .intervalsCreateWorkout,
					toolInput: .createWorkout(date: "1998-06-13", workout: workout),
					summary: "Z2",
					description: "Z2 ride",
					expiresAt: expires
				)),
			.proposalCleared(ProposalClearedBody(chatId: .main, nonce: nonce, reason: .executed)),
			.flushPending(FlushPendingBody(chatId: .main, trigger: .trim, messageUlids: [ulid])),
			.planningCommand(
				PlanningCommandBody(
					commandName: .creationStart,
					commandId: "cmd-1",
					requestDigest: "digest",
					status: .succeeded,
					result: .object([
						"ok": .bool(true),
						"n": .number(2),
						"s": .string("x"),
						"z": .null,
						"a": .array([.number(1)]),
					])
				)),
			.planRevision(
				PlanRevisionBody(
					planUlid: ulid, version: 1, status: .active,
					snapshot: .object(["name": .string("Base")]))),
			.mirrorJob(
				MirrorJobBody(
					planUlid: ulid,
					kind: .mirror,
					windowStart: DateKey.from("1998-06-13"),
					windowEnd: DateKey.from("1998-06-19"),
					failureCount: 0
				)),
			.workoutMatch(
				WorkoutMatchBody(planWorkoutId: ulid, activityId: "123456", decision: .confirmed)),
			.workoutDrift(WorkoutDriftBody(planWorkoutId: ulid, askedAt: expires)),
		]
		return synced.map { (kind: $0.kind.rawValue, body: RecordBody.synced($0)) }
			+ local.map { (kind: $0.kind.rawValue, body: RecordBody.deviceLocal($0)) }
	}
}
