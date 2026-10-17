import Foundation
import Testing

@testable import EnduragentCoach

struct StoredReviewFixture: Sendable, CustomTestStringConvertible {
	let name: String
	let cases: Set<StoredCase>
	let stage: Stage?

	var testDescription: String { name }

	static let all: [StoredReviewFixture] =
		approvals + tryAgains + refusals + blocks + [unconfirmed] + runs + ends

	private static let approvals: [StoredReviewFixture] = [
		StoredReviewFixture(
			"workout-review-approval",
			[.approvalPrepared, .add, .ride, .edit, .delete, .reviewedTarget],
			.waiting(.approval(.prepared))),
		StoredReviewFixture(
			"workout-review-revised", [.approvalRevised, .edit, .reviewedTarget],
			.waiting(.approval(.revised))),
		StoredReviewFixture(
			"workout-review-refreshed",
			[
				.approvalRefreshed, .differentDate, .differentDuration, .differentName,
				.differentDescription, .differentLoad, .differentStructure, .edit, .delete,
				.reviewedTarget,
			],
			.waiting(
				.approval(
					.refreshed([
						TargetDifference(
							change: reviewChange(413),
							before: WorkoutSnapshot(
								date: "1998-07-02", name: "Long endurance ride",
								durationSeconds: 7200, description: nil, load: nil, structure: nil),
							after: WorkoutSnapshot(
								date: "1998-07-03", name: "Long ride", durationSeconds: 10800,
								description: nil, load: nil, structure: nil)),
						TargetDifference(
							change: reviewChange(414),
							before: WorkoutSnapshot(
								date: "1998-07-04", name: nil, durationSeconds: nil,
								description: "Openers", load: 25,
								structure: #"{"steps":[{"duration":120}]}"#),
							after: WorkoutSnapshot(
								date: "1998-07-04", name: nil, durationSeconds: nil,
								description: "Openers\n- 3x1m 120%", load: 30,
								structure: #"{"steps":[{"duration":180}]}"#)),
					])))),
		StoredReviewFixture(
			"workout-review-approval-could-not-check", [.approvalCouldNotCheck, .add, .ride],
			.waiting(.approval(.couldNotCheck))),
		StoredReviewFixture(
			"workout-review-interrupted-before-writing",
			[.approvalInterruptedBeforeWriting, .delete, .reviewedTarget],
			.waiting(.approval(.interruptedBeforeWriting))),
	]

	private static let tryAgains: [StoredReviewFixture] = [
		StoredReviewFixture(
			"workout-review-not-saved",
			[.tryAgainNotSaved, .add, .ride, .saved, .edit, .reviewedTarget],
			.waiting(.tryAgain(.notSaved(reviewChange(418))))),
		StoredReviewFixture(
			"workout-review-try-again-could-not-check",
			[
				.tryAgainCouldNotCheck, .delete, .reviewedTarget, .noLongerOnCalendar, .add,
				.weightTraining,
			],
			.waiting(.tryAgain(.couldNotCheck))),
		StoredReviewFixture(
			"workout-review-interrupted",
			[.tryAgainInterrupted, .add, .ride, .seenOnCalendar, .delete, .reviewedTarget],
			.waiting(.tryAgain(.interrupted))),
		StoredReviewFixture(
			"workout-review-settled",
			[.tryAgainSettled, .edit, .reviewedTarget, .seenOnCalendar, .add, .ride],
			.waiting(.tryAgain(.settled))),
	]

	private static let refusals: [StoredReviewFixture] = [
		refusal("workout-review-refused-400", 425, .badRequest, .refusedBadRequest),
		refusal("workout-review-refused-401", 426, .unauthorized, .refusedUnauthorized),
		refusal("workout-review-refused-403", 427, .forbidden, .refusedForbidden),
		refusal("workout-review-refused-404", 428, .notFound, .refusedNotFound),
		StoredReviewFixture(
			"workout-review-try-again",
			[.tryAgainRefused, .refusedRateLimited, .edit, .reviewedTarget],
			.waiting(.tryAgain(.refused(reviewChange(406), .rateLimited)))),
	]

	private static let blocks: [StoredReviewFixture] = [
		block("workout-review-blocked-turn-stopping", .turnStopping, .blockedTurnStopping),
		StoredReviewFixture(
			"workout-review-blocked-training-not-connected",
			[.blockedTrainingNotConnected, .delete, .reviewedTarget],
			.waiting(.blocked(.trainingNotConnected)), account: .unconnectedAccount),
		block("workout-review-blocked-cannot-verify", .cannotVerify, .blockedCannotVerify),
		StoredReviewFixture(
			"workout-review-blocked", [.blockedAccountChanged, .delete, .upgradedTarget],
			.waiting(.blocked(.accountChanged))),
		block("workout-review-blocked-past-protected", .pastProtected, .blockedPastProtected),
		block("workout-review-blocked-coach-only", .coachOnly, .blockedCoachOnly),
		block("workout-review-blocked-workout-only", .workoutOnly, .blockedWorkoutOnly),
		StoredReviewFixture(
			"workout-review-blocked-reviewed-before-upgrade",
			[.blockedReviewedBeforeUpgrade, .edit, .upgradedTarget],
			.waiting(.blocked(.reviewedBeforeUpgrade))),
	]

	private static let unconfirmed = StoredReviewFixture(
		"workout-review-unconfirmed",
		[
			.unconfirmed, .add, .edit, .delete, .reviewedTarget, .upgradedTarget, .saved,
			.seenOnCalendar, .noLongerOnCalendar, .ride, .weightTraining,
		],
		nil)

	private static let runs: [StoredReviewFixture] = [
		StoredReviewFixture(
			"workout-review-checking",
			[.checking, .claimedTryAgain, .add, .ride, .saved, .delete, .reviewedTarget],
			.running(Run(claim: Claim(id: claimID(3), action: .tryAgain), sending: nil))),
		StoredReviewFixture(
			"workout-review-sending", [.sending, .claimedApprove, .add, .ride], nil),
	]

	private static let ends: [StoredReviewFixture] = [
		StoredReviewFixture(
			"workout-review-completed",
			[.completed, .delete, .reviewedTarget, .noLongerOnCalendar],
			.completed),
		StoredReviewFixture(
			"workout-review-canceled",
			[.canceledWithUnconfirmed, .delete, .edit, .upgradedTarget], nil),
		StoredReviewFixture(
			"workout-review-canceled-before-sending",
			[.canceledWithNothingUnconfirmed, .add, .ride],
			nil),
	]

	private init(
		_ name: String, _ cases: Set<StoredCase>, _ stage: Stage?,
		account: StoredCase = .intervalsAccount
	) {
		self.name = name
		self.cases = cases.union([account])
		self.stage = stage
	}

	private static func refusal(
		_ name: String, _ change: Int, _ status: RefusalStatus, _ storedStatus: StoredCase
	) -> StoredReviewFixture {
		StoredReviewFixture(
			name, [.tryAgainRefused, storedStatus, .delete, .reviewedTarget],
			.waiting(.tryAgain(.refused(reviewChange(change), status))))
	}

	private static func block(_ name: String, _ block: ReviewBlock, _ storedBlock: StoredCase)
		-> StoredReviewFixture
	{
		StoredReviewFixture(
			name, [storedBlock, .delete, .reviewedTarget], .waiting(.blocked(block)))
	}
}
