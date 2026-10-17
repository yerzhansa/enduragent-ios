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
			RecordQuery(scope: .deviceLocal([.pendingProposal]))
		).records
		let proposal = try #require(proposals.last)
		guard case .operation(.turn(let turn), _) = proposal.cause,
			case .deviceLocal(.pendingProposal(let body)) = proposal.body
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
			ledger: Ledger(
				log: store ?? log, clock: clock, diagnostics: DiagnosticsLog(clock: clock)),
			clock: clock, diagnostics: DiagnosticsLog(clock: clock),
			training: { _ in
				.connected(
					ConnectedTraining(connection: connection, athlete: athlete, client: calendar))
			}, host: ImmediateExecutionHost())
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
