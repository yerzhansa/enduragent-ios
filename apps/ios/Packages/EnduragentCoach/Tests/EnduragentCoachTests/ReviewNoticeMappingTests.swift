import Foundation
import Testing

@testable import EnduragentCoach

struct ReviewNoticeMappingTests {
	struct Row: CustomTestStringConvertible, Sendable {
		let name: String
		let outcome: ReviewOutcome
		let notice: AthleteNotice?

		var testDescription: String { name }
	}

	static let pending = ReviewNotice(
		kind: .partialFailure, key: Catalog.reviewWritePending, vars: [:])
	static let readFailed = ReviewNotice(
		kind: .partialFailure, key: Catalog.reviewWriteReadFailed, vars: [:])
	static let serviceNotice = ReviewNotice(
		kind: .refreshedAfterStaleTarget, key: Catalog.reviewWriteReadFailed,
		vars: ["service": "intervals.icu"])
	static let saved = [ReviewReceipt(index: 0, progress: .saved(EventID(rawValue: 1)))]
	static let intervals: [String: CatalogArgument] = ["service": .text("intervals.icu")]

	static let workoutReview: [Row] = [
		Row(
			name: "stopped", outcome: .stopped(saved, serviceNotice),
			notice: AthleteNotice(key: Catalog.reviewWriteReadFailed, vars: intervals, actions: [])),
		Row(
			name: "unconfirmed with receipts", outcome: .unconfirmed(saved, pending),
			notice: AthleteNotice(key: Catalog.reviewWritePending, actions: [])),
		Row(
			name: "refreshed", outcome: .refreshed(serviceNotice),
			notice: AthleteNotice(key: Catalog.reviewWriteReadFailed, vars: intervals, actions: [])),
		Row(name: "completed with receipts", outcome: .completed(saved), notice: nil),
		Row(name: "canceled with receipts", outcome: .canceled(saved), notice: nil),
		Row(name: "wrongAction", outcome: .wrongAction, notice: nil),
		Row(
			name: "staleControl with a newer review",
			outcome: .staleControl(
				newer: ReviewRef(
					chat: .main, review: WorkoutReviewID(ulid: reviewULID(101)),
					revision: ReviewRevision(rawValue: 2), delivery: UUID())),
			notice: AthleteNotice(key: Catalog.coachConfirmationExpired, actions: [])),
		Row(name: "presentationRecorded", outcome: .presentationRecorded, notice: nil),
		Row(
			name: "unconfirmed after a lost answer",
			outcome: .unconfirmed(
				[],
				ReviewNotice(
					kind: .partialFailure, key: Catalog.reviewUncertain,
					vars: ["service": "intervals.icu"])),
			notice: AthleteNotice(key: Catalog.reviewUncertain, vars: intervals, actions: [])),
		Row(
			name: "stopped with an unreadable account",
			outcome: .stopped(
				[],
				ReviewNotice(
					kind: .partialFailure, key: Catalog.reviewCannotVerify,
					vars: ["service": "intervals.icu"])),
			notice: AthleteNotice(key: Catalog.reviewCannotVerify, vars: intervals, actions: [])),
		Row(
			name: "blocked accountChanged", outcome: .blocked(.accountChanged),
			notice: AthleteNotice(key: Catalog.reviewAccountChanged, vars: intervals, actions: [])),
		Row(
			name: "blocked trainingNotConnected", outcome: .blocked(.trainingNotConnected),
			notice: AthleteNotice(key: Catalog.connectMissing, actions: [.connectTraining])),
		Row(
			name: "blocked cannotVerify", outcome: .blocked(.cannotVerify),
			notice: AthleteNotice(key: Catalog.reviewCannotVerify, vars: intervals, actions: [])),
		Row(
			name: "storageUnavailable", outcome: .storageUnavailable,
			notice: AthleteNotice(key: Catalog.reviewSaveFailed, actions: [])),
		Row(
			name: "blocked reviewedBeforeUpgrade", outcome: .blocked(.reviewedBeforeUpgrade),
			notice: AthleteNotice(key: Catalog.workoutsBlockedReviewedBeforeUpgrade, actions: [])),
		Row(
			name: "blocked pastProtected", outcome: .blocked(.pastProtected),
			notice: AthleteNotice(key: Catalog.coachErrorUnknown, actions: [])),
		Row(
			name: "blocked coachOnly", outcome: .blocked(.coachOnly),
			notice: AthleteNotice(key: Catalog.coachErrorUnknown, actions: [])),
		Row(
			name: "blocked workoutOnly", outcome: .blocked(.workoutOnly),
			notice: AthleteNotice(key: Catalog.coachErrorUnknown, actions: [])),
	]

	@Test(arguments: workoutReview)
	func eachWorkoutReviewOutcomeGivesItsNotice(_ row: Row) {
		#expect(row.outcome.notice == row.notice)
	}

	@Test func aReviewBlockedBeforeTheUpgradeAsksForTheCoachAgain() throws {
		let notice = try #require(AthleteNotices.notice(for: .blocked(.reviewedBeforeUpgrade)))
		#expect(notice.key.rawValue == "workouts.blocked.reviewedBeforeUpgrade")
		#expect(notice.actions.isEmpty)
		#expect(
			CatalogPhrasebook(tag: .en).say(notice.key)
				== "This workout was reviewed before the app was updated. Ask the coach again.")
	}
}
