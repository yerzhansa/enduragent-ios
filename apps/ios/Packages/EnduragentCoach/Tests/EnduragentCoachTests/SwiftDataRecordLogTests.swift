import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
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
			let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
			let ledger = Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
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

		@Test func failedSavedWorkAndInterruptedSettlementsRoundTrip() async throws {
			let log = try makeSwiftDataLog(deviceId: phoneA)
			let ulid = ULID.generate(at: Date(timeIntervalSince1970: 899_164_800))
			let turn = TurnID(ulid: ulid)
			let saved = WriteSummary(
				memorySections: 1, ledgerEvents: 2, planSaves: 0, calendarWrites: 0)
			let bodies: [SyncedRecordBody] = [
				.turnSettled(
					TurnSettledBody(
						chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid),
						settlement: .failed(.model(.providerDown(.timeout)), saved: .none))),
				.turnSettled(
					TurnSettledBody(
						chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid),
						settlement: .failed(.model(.budgetExhausted(.wallClock)), saved: saved))),
				.turnSettled(
					TurnSettledBody(
						chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid),
						settlement: .failed(.local(.recordStorage), saved: .none))),
				.turnSettled(
					TurnSettledBody(
						chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid),
						settlement: .savedWork(.savedUnverified, saved: saved))),
				.turnSettled(
					TurnSettledBody(
						chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid),
						settlement: .savedWork(.writesSaved, saved: saved))),
				.turnSettled(
					TurnSettledBody(
						chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid),
						settlement: .interrupted(
							partial: "Thursday is", cause: .athleteStopped, saved: saved))),
			]
			for (index, body) in bodies.enumerated() {
				try await log.append(
					[storedRecord(device: phoneA, wall: Int64(index + 1), body: .synced(body))],
					locality: .synced)
			}
			let fetched = try await log.fetch(
				RecordQuery(scope: .synced([.turnSettled]), turn: turn))
			#expect(fetched.skipped.isEmpty)
			#expect(fetched.records.map(\.body) == bodies.map(RecordBody.synced))
		}

		@Test(arguments: [
			ModelFailure.credentialRejected(.credits), .credentialRejected(.openRouterAccount),
			.accessExhausted(.credits), .rateLimited(retryAfter: .milliseconds(1_500)),
			.rateLimited(retryAfter: nil), .invalidRequest, .contextOverflow,
			.generationFailed(.malformedStream), .accessUnavailable(.notConfigured(.credits)),
			.accessUnavailable(.secureStorageLocked), .accessUnavailable(.secureStorageUnavailable),
			.accessUnavailable(.malformedStoredCredential(.creditsAccount)),
			.accessUnavailable(.malformedStoredCredential(.intervalsConnection)),
		])
		func everyModelFailureSurvivesTheStore(failure: ModelFailure) async throws {
			let log = try makeSwiftDataLog(deviceId: phoneA)
			let ulid = ULID.generate(at: Date(timeIntervalSince1970: 899_164_800))
			let body = SyncedRecordBody.turnSettled(
				TurnSettledBody(
					chatId: .main, turn: TurnID(ulid: ulid), attempt: AttemptID(ulid: ulid),
					settlement: .failed(.model(failure), saved: .none)))
			try await log.append(
				[storedRecord(device: phoneA, wall: 1, body: .synced(body))], locality: .synced)
			let fetched = try await log.fetch(RecordQuery(scope: .synced([.turnSettled])))
			#expect(fetched.skipped.isEmpty)
			#expect(fetched.records.map(\.body) == [.synced(body)])
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
			let page = try await log.fetch(
				RecordQuery(scope: .synced([.userMessage]), chatId: .main))
			#expect(page.records.count == 100)
			#expect(page.records == batch.filter { $0.chatId == .main })
		}

		@Test func syncedFaultsRejectEverySyncedKindAndLeaveLocalRecordsWritable() async throws {
			let fixture = try RecordStore.fixture(
				directory: FileManager.default.temporaryDirectory.appending(
					path: "enduragent-synced-faults-\(UUID().uuidString)",
					directoryHint: .isDirectory),
				deviceId: phoneA)
			let samples = try sampleBodies()
			fixture.faults.failSyncedAppends = true
			for kind in SyncedKind.allCases {
				let sample = try #require(samples.first { $0.kind == kind.rawValue })
				let record = storedRecord(device: phoneA, wall: 1, body: sample.body)
				await #expect(
					throws: RecordStorageFault(operation: .append(kinds: [kind.rawValue]))
				) {
					try await fixture.store.log.append([record], locality: .synced)
				}
			}
			#expect(
				try await fixture.store.log.fetch(RecordQuery(scope: .everySynced)).records.isEmpty)
			for sample in samples where sample.body.locality == .deviceLocal {
				try await fixture.store.log.append(
					[storedRecord(device: phoneA, wall: 2, body: sample.body)],
					locality: .deviceLocal)
			}
			let local = try await fixture.store.log.fetch(RecordQuery(scope: .everyDeviceLocal))
				.records
			#expect(Set(local.map(\.body.kind)) == Set(DeviceLocalKind.allCases.map(\.rawValue)))
			fixture.faults.failSyncedAppends = false
			let saved = storedRecord(
				device: phoneA, wall: 3, body: .synced(sampleUser(chatId: .main, text: "saved")))
			try await fixture.store.log.append([saved], locality: .synced)
			#expect(
				try await fixture.store.log.fetch(RecordQuery(scope: .everySynced)).records == [
					saved
				])
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
						reason: .reset(ResetID(ulid: ulid)))),
				.compactionSummary(CompactionSummaryBody(chatId: .main, markdown: "sum")),
				.reviewApplied(
					ReviewAppliedBody(
						chatId: .main,
						summary: .createWorkout(name: "Endurance", date: "1998-06-14"))),
				.memorySection(MemorySectionBody(name: .person, content: "Ada")),
				.dailyNote(DailyNoteBody(note: "note")),
				.ledgerEvent(
					LedgerEventBody(
						date: "1998-06-10", kind: .decision, text: "Keep Saturdays free.",
						source: .chat
					)),
				.journal(JournalBody(op: .writeSection, preview: "person")),
				.provenance(
					ProvenanceBody(
						key: "k", garmin: true, nonGarmin: false, unknown: false,
						contentSha256: "abc")),
				.coachReplyLanguage(CoachReplyLanguageBody(tag: .it)),
				.planningDevice(
					PlanningDeviceBody(
						planningDeviceId: phoneA, planUlid: ulid, activatedAt: expires)),
				.sessionSettings(
					SessionSettingsBody(
						settings: try SessionSettings.npmDefaults
							.replacing(.historyBudgetRatio, with: "0.05")
							.replacing(.contextWindowOverride, with: "64000")
							.replacing(.compactionModel, with: "test/compact")
							.replacing(.flushModel, with: "test/flush"))),
				.languagePreference(LanguagePreferenceBody(preference: .fixed(.fr))),
			]
			let local: [DeviceLocalRecordBody] = [
				.turnClaim(
					TurnClaimBody(
						chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid),
						lease: .continuedProcessing)),
				.replyObserved(
					ReplyObservedBody(chatId: .main, turn: turn, attempt: AttemptID(ulid: ulid))),
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
				.proposalCleared(
					ProposalClearedBody(chatId: .main, nonce: nonce, reason: .canceled)),
				.flushPending(
					FlushPendingBody(chatId: .main, messageUlids: [ulid])),
				.flushSettled(
					FlushSettledBody(
						chatId: .main, job: FlushJobID(ulid: ulid),
						settlement: .saved(sections: 2, events: 1))),
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
					WorkoutMatchBody(
						planWorkoutId: ulid, activityId: "123456", decision: .confirmed)),
				.workoutDrift(WorkoutDriftBody(planWorkoutId: ulid, askedAt: expires)),
			]
			return synced.map { (kind: $0.kind.rawValue, body: RecordBody.synced($0)) }
				+ local.map { (kind: $0.kind.rawValue, body: RecordBody.deviceLocal($0)) }
		}
	}
}
