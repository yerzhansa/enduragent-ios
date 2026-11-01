import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct M2Seed {
	enum Landing: String, CaseIterable, CustomTestStringConvertible {
		case bulkUpsert, singleCreate

		var testDescription: String { rawValue }
	}

	static let folder = "Fixtures/build-6833d90f"
	static let device = "build-6833d90f"

	let log: SwiftDataRecordLog
	let clock = FixedClock(now: "1998-06-15T08:05:00Z", timeZone: "Europe/Ljubljana")
	let calendar = ScriptedCalendar(FakeIntervalsClient(athleteName: "Ada", ftp: 250))
	let account: TrainingAccount
	let review: WorkoutReviewID
	let turn: TurnID
	let identity: CalendarWriteID

	init(_ log: SwiftDataRecordLog) async throws {
		self.log = log
		let proposals = try await log.fetch(
			RecordQuery(scope: .deviceLocal([], includeLegacy: [.pendingProposal]))
		).records
		let proposal = try #require(proposals.last)
		guard case .operation(.turn(let turn), _) = proposal.cause,
			case .legacy(.pendingProposal(let body)) = proposal.body
		else {
			throw UnexpectedReview(detail: "the seed proposal has no turn")
		}
		self.turn = turn
		account = proposal.account
		review = WorkoutReviewID(ulid: proposal.ulid)
		identity = try #require(body.writeID)
	}

	func desk(over store: (any ReviewChainLog)? = nil) throws -> WorkoutReviewDesk {
		guard case .intervals(let connection, let athlete?) = account else {
			throw UnexpectedReview(detail: "the seed account is not an intervals.icu athlete")
		}
		let calendar = calendar
		return WorkoutReviewDesk(
			ledger: ledger(over: store), clock: clock, diagnostics: DiagnosticsLog(clock: clock),
			training: { _ in
				.connected(
					ConnectedTraining(connection: connection, athlete: athlete, client: calendar))
			}, host: ImmediateExecutionHost())
	}

	func coach(transport: FakeModelTransport = FakeModelTransport()) async throws -> Coach {
		guard case .intervals(let connection, let athlete?) = account else {
			throw UnexpectedReview(detail: "the seed account is not an intervals.icu athlete")
		}
		let secrets = keyedSecrets()
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: connection, credential: .apiKey("icu-test-key"), selection: .keyOwner,
				resolvedAthlete: athlete))
		return await makeCoach(
			transport: transport, intervals: calendar, store: log, clock: clock, secrets: secrets)
	}

	func calendarReads() -> Int {
		calendar.calls.filter { $0 == .read }.count
	}

	func landTheUnknownAdd() {
		calendar.base.events.append(
			CalendarEvent(
				description: "- 10m 55-65%\n\n2x\n- 10m 190-225w\n- 5m Z1-Z2\n\n- 10m 55-65%",
				type: "Ride", id: EventID(rawValue: 7001), startDateLocal: "1998-06-16T00:00:00",
				name: "Endurance with tempo", category: "WORKOUT", externalId: identity.externalID,
				uid: identity.uid, tags: [IntervalsPolicy.coachTag], coachCreated: true))
	}

	func ledger(over store: (any ReviewChainLog)? = nil) -> Ledger {
		Ledger(log: store ?? log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
	}

	func added(_ review: WorkoutReview) throws -> AddedWorkout {
		let change: ReviewChange
		if case .waiting(.unconfirmed(let attempt)) = review.stage {
			change = attempt.change
		} else {
			change = try #require(review.work.remaining.first)
		}
		guard case .add(let added) = change.action else {
			throw UnexpectedReview(detail: "the upgraded review holds no add")
		}
		return added
	}

	func chain() async throws -> [WorkoutReview] {
		try await log.fetch(RecordQuery(scope: .deviceLocal([.workoutReview]))).records
			.compactMap { record in
				guard case .deviceLocal(.workoutReview(let body)) = record.body else { return nil }
				return body.review
			}
	}

	func outcomes() async throws -> [ReviewOutcomeBody] {
		try await log.fetch(RecordQuery(scope: .synced([.reviewOutcome]))).records
			.compactMap { record in
				guard case .synced(.reviewOutcome(let body)) = record.body else { return nil }
				return body
			}
	}
}
