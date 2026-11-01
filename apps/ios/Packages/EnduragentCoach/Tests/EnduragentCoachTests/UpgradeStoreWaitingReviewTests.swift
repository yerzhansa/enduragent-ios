import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites.UpgradeStoreTests {
	static let milestoneFourFolder = "Fixtures/build-d6f89d9b"
	static let milestoneFourDevice = "build-d6f89d9b"
	static let tempoSteps =
		#"{"steps":[{"warmup":true,"duration":600,"power":{"units":"%ftp","start":50,"end":65},"_power":{"start":125,"end":162.5},"cadence":{"units":"rpm","value":90}},{"reps":2,"steps":[{"duration":480,"power":{"units":"%ftp","value":87.5},"_power":{"value":218.75},"hr":{"units":"%lthr","value":88.3}},{"duration":240,"power":{"units":"%ftp","value":55},"_power":{"value":137.5}}]},{"cooldown":true,"duration":600,"power":{"units":"%ftp","value":50},"_power":{"value":168.33333333333334},"text":"Easy spin"}],"duration":3360,"ftp":250}"#

	static let reprintedSteps =
		#"{"steps":[{"duration":600,"power":{"units":"%ftp","value":0.00005},"_power":{"value":9007199254740992}},{"duration":600,"hr":{"units":"%lthr","value":1e-9},"cadence":{"units":"rpm","value":1e16}}],"duration":1200,"ftp":250}"#
	static let reprintedStructure =
		#"{"steps":[{"_power":{"value":9007199254740992.0},"duration":600,"power":{"units":"%ftp","value":5e-05}},{"cadence":{"units":"rpm","value":1e+16},"duration":600,"hr":{"units":"%lthr","value":1e-09}}]}"#
	static let longDigitSteps =
		#"{"steps":[{"duration":600,"power":{"units":"%ftp","value":0.00005},"_power":{"value":9007199254740992}},{"duration":600,"hr":{"units":"%lthr","value":1e-9},"cadence":{"units":"rpm","value":1e16}},{"duration":600,"power":{"units":"%ftp","value":1.2345678901234568e-05},"_power":{"value":1.2345678901234568e+20}}],"duration":1800,"ftp":250}"#
	static let longDigitStructure =
		#"{"steps":[{"_power":{"value":9007199254740992.0},"duration":600,"power":{"units":"%ftp","value":5e-05}},{"cadence":{"units":"rpm","value":1e+16},"duration":600,"hr":{"units":"%lthr","value":1e-09}},{"_power":{"value":1.2345678901234568e+20},"duration":600,"power":{"units":"%ftp","value":1.2345678901234568e-05}}]}"#
	static let misreadStructure =
		#"{"steps":[{"_power":{"value":218.75},"duration":600,"power":{"units":"%ftp","value":87.5}},{"_power":{"value":137.5},"duration":600,"hr":{"units":"%lthr","value":0.05185376836363068},"power":{"units":"%ftp","value":55}}]}"#
	static let misreadEvent =
		#"{"id":4101,"start_date_local":"1998-06-17T00:00:00","name":"Tempo ride","category":"WORKOUT","external_id":null,"uid":null,"tags":["cycling-coach"],"description":"Two tempo blocks","type":"Ride","moving_time":3360,"icu_training_load":58,"workout_doc":{"steps":[{"duration":600,"power":{"units":"%ftp","value":87.5},"_power":{"value":218.75}},{"duration":600,"power":{"units":"%ftp","value":55},"_power":{"value":137.5},"hr":{"units":"%lthr","value":0.051853768363630676}}],"duration":1200,"ftp":250}}"#
	static let milestoneFiveClock = FixedClock(
		now: "1998-06-15T08:05:00Z", timeZone: "Europe/Ljubljana")

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
		guard case .completed = try await Self.approve(review, over: log, calendar: calendar)
		else {
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

	@Test func buildD6f89d9bReviewOfReprintedNumbersApprovesWithoutARefresh() async throws {
		let log = try open(
			"reprinted-numbers", folder: Self.milestoneFourFolder, device: Self.milestoneFourDevice)
		let review = try #require(try await workoutReviews(in: log).last)
		let ride = try Self.tempoRide(Self.longDigitSteps)
		#expect(try Self.reviewedStructure(of: review) == Self.longDigitStructure)
		#expect(try ride.snapshot.structure != Self.longDigitStructure)

		let calendar = ScriptedCalendar(FakeIntervalsClient(athleteName: "Ada", ftp: 250))
		calendar.base.events = [ride]
		guard case .completed = try await Self.approve(review, over: log, calendar: calendar)
		else {
			Issue.record("approving the restored review did not complete")
			return
		}
		#expect(try await workoutReviews(in: log).last?.stage == .completed)
		guard case .update(let written, let patch) = try #require(calendar.writes.first) else {
			Issue.record("the approval wrote no edit")
			return
		}
		#expect(calendar.writes.count == 1)
		#expect(written == ride.id)
		#expect(patch.name == "Tempo 2x8")
	}

	@Test func buildD6f89d9bReviewOfReprintedNumbersRefusesARevisionThatChangesNothing()
		async throws
	{
		let log = try open(
			"reprinted-numbers", folder: Self.milestoneFourFolder, device: Self.milestoneFourDevice)
		let review = try #require(try await workoutReviews(in: log).last)

		let refusal = try await Self.revise(
			review, over: log, on: try Self.tempoRide(Self.longDigitSteps),
			to: #"{"kind":"edit","eventId":4101,"patch":{"durationSeconds":3360}}"#)

		#expect(refusal == "unchanged_item")
		#expect(try await workoutReviews(in: log).last == review)
	}

	@Test func buildD6f89d9bAuthoredEditOfReprintedNumbersRefusesTheSameStepsAsAWorkoutDocument()
		async throws
	{
		let log = try open(
			"reprinted-authored-steps", folder: Self.milestoneFourFolder,
			device: Self.milestoneFourDevice)
		let review = try #require(try await workoutReviews(in: log).last)
		guard case .edit(let edit) = try #require(review.work.remaining.first).action,
			case .reviewed(_, let stored) = edit.target
		else {
			Issue.record("the seed review holds no reviewed edit")
			return
		}
		#expect(edit.patch.authoredSteps?.json == (try JSONValue.parse(ReviewTurns.authoredSteps)))
		#expect(stored.description == edit.patch.description)
		#expect(stored.structure == Self.reprintedStructure)
		var ride = try Self.tempoRide(Self.reprintedSteps)
		ride.description = edit.patch.description

		let refusal = try await Self.revise(
			review, over: log, on: ride,
			to: #"{"kind":"edit","eventId":4101,"patch":{"structure":\#(Self.reprintedSteps)}}"#)

		#expect(refusal == "unchanged_item")
		#expect(try await workoutReviews(in: log).last == review)
	}

	@Test func buildD6f89d9bReviewOfReprintedNumbersNamesAChangedNumberAsAStructureChange()
		async throws
	{
		let log = try open(
			"reprinted-numbers", folder: Self.milestoneFourFolder, device: Self.milestoneFourDevice)
		let review = try #require(try await workoutReviews(in: log).last)
		let calendar = ScriptedCalendar(FakeIntervalsClient(athleteName: "Ada", ftp: 250))
		calendar.base.events = [
			try Self.tempoRide(
				Self.longDigitSteps.replacingOccurrences(of: "0.00005", with: "0.00006"))
		]

		guard case .refreshed = try await Self.approve(review, over: log, calendar: calendar)
		else {
			Issue.record("approving after a changed number did not refresh the review")
			return
		}
		guard
			case .waiting(.approval(.refreshed(let differences))) = try #require(
				try await workoutReviews(in: log).last
			).stage
		else {
			Issue.record("the refreshed review names no differences")
			return
		}
		#expect(differences.map(\.fields) == [[.structure]])
		#expect(calendar.writes.isEmpty)
	}

	@Test func buildD6f89d9bReviewOfANumberItsReaderMisreadRefreshesOnceAndThenApproves()
		async throws
	{
		let log = try open(
			"misread-intervals-number", folder: Self.milestoneFourFolder,
			device: Self.milestoneFourDevice)
		let review = try #require(try await workoutReviews(in: log).last)
		#expect(try Self.reviewedStructure(of: review) == Self.misreadStructure)
		let ride = try await Self.intervalsEvent(Self.misreadEvent)
		let calendar = ScriptedCalendar(FakeIntervalsClient(athleteName: "Ada", ftp: 250))
		calendar.base.events = [ride]

		guard case .refreshed = try await Self.approve(review, over: log, calendar: calendar)
		else {
			Issue.record("approving over the exact number did not refresh the review")
			return
		}
		let refreshed = try #require(try await workoutReviews(in: log).last)
		guard case .waiting(.approval(.refreshed(let differences))) = refreshed.stage else {
			Issue.record("the refreshed review names no differences")
			return
		}
		#expect(differences.map(\.fields) == [[.structure]])
		#expect(calendar.writes.isEmpty)

		guard case .completed = try await Self.approve(refreshed, over: log, calendar: calendar)
		else {
			Issue.record("approving the refreshed review did not complete")
			return
		}
		#expect(try await workoutReviews(in: log).last?.stage == .completed)
		guard case .update(let written, let patch) = try #require(calendar.writes.first) else {
			Issue.record("the approval wrote no edit")
			return
		}
		#expect(calendar.writes.count == 1)
		#expect(written == ride.id)
		#expect(patch.name == "Tempo 2x8")
	}

	private static func reviewedStructure(of review: WorkoutReview) throws -> String? {
		guard case .edit(let edit) = try #require(review.work.remaining.first).action,
			case .reviewed(_, let stored) = edit.target
		else {
			throw UnexpectedReview(detail: "the seed review holds no reviewed edit")
		}
		return stored.structure
	}

	private static func revise(
		_ review: WorkoutReview, over log: SwiftDataRecordLog, on ride: CalendarEvent,
		to change: String
	) async throws -> String? {
		let turns = ReviewTurns(clock: milestoneFiveClock)
		turns.intervals.events = [ride]
		let coach = await turns.coach(over: log)
		let item = try #require(review.work.remaining.first)
		_ = try await turns.reply(
			after: [turns.prepare(turns.revise(review, [(item.reference, change)]))], on: coach)
		return try turns.toolData().first?.objectFields["error"]?.stringValue
	}

	private static func approve(
		_ review: WorkoutReview, over log: SwiftDataRecordLog, calendar: ScriptedCalendar
	) async throws -> ReviewOutcome {
		let desk = try desk(for: review.account, over: log, calendar: calendar)
		let shown = try #require(try await desk.snapshot(chat: .main))
		#expect(await desk.decide(.presented(shown.ref)) == .presentationRecorded)
		guard
			case .armed(.approveOrCancel, let token) = try #require(
				try await desk.snapshot(chat: .main)
			).controls
		else {
			throw UnexpectedReview(detail: "the restored review offered no Approve")
		}
		return await desk.decide(.approve(token))
	}

	private static func intervalsEvent(_ text: String) async throws -> CalendarEvent {
		let read = await CalendarWriterLine.answering(.status(200, text)) { client in
			do {
				return Result<CalendarEvent, any Error>.success(
					try await client.fetchEvent(id: EventID(rawValue: 4101)))
			} catch {
				return .failure(error)
			}
		}
		#expect(read.sent.map(\.method) == ["GET"])
		return try read.result.get()
	}

	private static func tempoRide(_ steps: String = tempoSteps) throws -> CalendarEvent {
		CalendarEvent(
			description: "Two tempo blocks", type: "Ride", id: EventID(rawValue: 4101),
			startDateLocal: "1998-06-17T00:00:00", name: "Tempo ride", category: "WORKOUT",
			externalId: nil, uid: nil, tags: [IntervalsPolicy.coachTag], coachCreated: true,
			movingTime: 3360, trainingLoad: 58, workoutDocument: try JSONValue.parse(steps))
	}

	private static func desk(
		for account: TrainingAccount, over log: SwiftDataRecordLog, calendar: ScriptedCalendar
	) throws -> WorkoutReviewDesk {
		guard case .intervals(let connection, let athlete?) = account else {
			throw UnexpectedReview(detail: "the seed account is not an intervals.icu athlete")
		}
		let clock = milestoneFiveClock
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
