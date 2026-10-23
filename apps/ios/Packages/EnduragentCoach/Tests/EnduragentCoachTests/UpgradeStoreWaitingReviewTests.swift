import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites.UpgradeStoreTests {
	static let milestoneFourFolder = "Fixtures/build-d6f89d9b"
	static let milestoneFourDevice = "build-d6f89d9b"
	static let tempoSteps =
		#"{"steps":[{"warmup":true,"duration":600,"power":{"units":"%ftp","start":50,"end":65},"_power":{"start":125,"end":162.5},"cadence":{"units":"rpm","value":90}},{"reps":2,"steps":[{"duration":480,"power":{"units":"%ftp","value":87.5},"_power":{"value":218.75},"hr":{"units":"%lthr","value":88.3}},{"duration":240,"power":{"units":"%ftp","value":55},"_power":{"value":137.5}}]},{"cooldown":true,"duration":600,"power":{"units":"%ftp","value":50},"_power":{"value":168.33333333333334},"text":"Easy spin"}],"duration":3360,"ftp":250}"#

	@Test func buildD6f89d9bWaitingReviewKeepsItsDigestAndApprovesWithoutARefresh() async throws {
		let log = try open(
			"waiting-review", folder: Self.milestoneFourFolder, device: Self.milestoneFourDevice)
		let reviews = try await workoutReviews(in: log)
		#expect(reviews.count == 1)
		let review = try #require(reviews.last)
		#expect(review.revision == ReviewRevision(rawValue: 1))
		#expect(review.stage == .waiting(.approval(.prepared)))
		let tempoRide = try Self.tempoRide()
		guard case .edit(let edit) = try #require(review.work.remaining.first).action,
			case .reviewed(let event, let stored) = edit.target
		else {
			Issue.record("the seed review holds no reviewed edit")
			return
		}
		#expect(event == tempoRide.id)
		#expect(stored.structure != nil)
		#expect(stored.structure == (try tempoRide.snapshot).structure)

		let calendar = ScriptedCalendar(FakeIntervalsClient(athleteName: "Ada", ftp: 250))
		calendar.base.events = [tempoRide]
		let desk = try Self.desk(for: review.account, over: log, calendar: calendar)
		let shown = try #require(try await desk.snapshot(chat: .main))
		#expect(await desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(.approveOrCancel, let token) = try #require(
				try await desk.snapshot(chat: .main)
			).controls
		else {
			Issue.record("the restored review offered no Approve")
			return
		}
		guard case .completed = await desk.decide(.approve(token)) else {
			Issue.record("approving the restored review did not complete")
			return
		}
		#expect(try await workoutReviews(in: log).last?.stage == .completed)
		guard case .update(let written, let patch) = try #require(calendar.writes.first) else {
			Issue.record("the approval wrote no edit")
			return
		}
		#expect(calendar.writes.count == 1)
		#expect(written == tempoRide.id)
		#expect(patch.name == "Tempo 2x8")
	}

	@Test func buildD6f89d9bKeepsItsMemoryJournalAndSettledTurns() async throws {
		let log = try open(
			"waiting-review", folder: Self.milestoneFourFolder, device: Self.milestoneFourDevice)
		let synced = try await log.fetch(RecordQuery(scope: .everySynced))
		let local = try await log.fetch(RecordQuery(scope: .everyDeviceLocal))
		#expect(synced.skipped.isEmpty)
		#expect(local.skipped.isEmpty)
		let kinds = synced.records.map(\.body.kind)
		#expect(kinds.filter { $0 == SyncedKind.memorySection.rawValue }.count == 1)
		#expect(kinds.filter { $0 == SyncedKind.journal.rawValue }.count == 1)
		#expect(kinds.filter { $0 == SyncedKind.turnSettled.rawValue }.count == 2)
	}

	private static func tempoRide() throws -> CalendarEvent {
		CalendarEvent(
			description: "Two tempo blocks", type: "Ride", id: EventID(rawValue: 4101),
			startDateLocal: "1998-06-17T00:00:00", name: "Tempo ride", category: "WORKOUT",
			externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag], coachCreated: true,
			movingTime: 3360, trainingLoad: 58, workoutDocument: try JSONValue.parse(tempoSteps))
	}

	private static func desk(
		for account: TrainingAccount, over log: SwiftDataRecordLog, calendar: ScriptedCalendar
	) throws -> WorkoutReviewDesk {
		guard case .intervals(let connection, let athlete?) = account else {
			throw UnexpectedReview(detail: "the seed account is not an intervals.icu athlete")
		}
		let clock = FixedClock(now: "1998-06-15T08:05:00Z", timeZone: "Europe/Ljubljana")
		return WorkoutReviewDesk(
			ledger: Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock, diagnostics: DiagnosticsLog(clock: clock),
			training: { _ in
				.connected(
					ConnectedTraining(connection: connection, athlete: athlete, client: calendar))
			}, host: ImmediateExecutionHost())
	}

	private func workoutReviews(in log: SwiftDataRecordLog) async throws -> [WorkoutReview] {
		try await log.fetch(RecordQuery(scope: .deviceLocal([.workoutReview]))).records
			.compactMap { record in
				guard case .deviceLocal(.workoutReview(let body)) = record.body else { return nil }
				return body.review
			}
	}
}
