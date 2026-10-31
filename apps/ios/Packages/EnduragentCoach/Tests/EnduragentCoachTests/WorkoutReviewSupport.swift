import Foundation
import Testing

@testable import EnduragentCoach

func reviewULID(_ number: Int) -> ULID {
	guard let ulid = ULID(rawValue: "00T47DW5000000000000000\(number)") else {
		preconditionFailure("review fixture ids are valid ULIDs")
	}
	return ulid
}

func reviewChange(_ number: Int) -> ChangeID {
	ChangeID(ulid: reviewULID(number))
}

func claimID(_ number: Int) -> ClaimID {
	ClaimID(ulid: reviewULID(500 + number))
}

func reviewFixture(_ name: String) throws -> WorkoutReview {
	try WorkoutReviewPayload.decode(try fixtureData(name))
}

let reviewClock = Date(timeIntervalSince1970: 897_984_100)

enum ReviewStage: String, CaseIterable, CustomTestStringConvertible {
	case approval, tryAgain, unconfirmed, blocked, checking, sending
	case checkingAfterWork, sendingLast, unconfirmedUpgraded, completed, canceled

	var testDescription: String { rawValue }
}

struct ReviewStages {
	let values: [ReviewStage: WorkoutReview]
	let receipt: Receipt

	init() throws {
		let approval = try reviewFixture("workout-review-approval")
		let upgraded = try reviewFixture("workout-review-unconfirmed")
		guard case .saved(let receipt) = try #require(upgraded.work.finished.first).result else {
			throw UnexpectedReview(detail: "the fixture's first finished change has no Receipt")
		}
		let checking = try approval.claimed(Claim(id: claimID(1), action: .approve))
		let sending = try checking.sending(at: reviewClock, seen: [:])
		let resumed = try #require(try upgraded.settled(.seen(EventID(rawValue: 103))))
		let checkingAfterWork = try resumed.claimed(Claim(id: claimID(2), action: .tryAgain))
		let sendingLast = try checkingAfterWork.sending(at: reviewClock, seen: [:])
		let completed = try next(try sendingLast.answered(.saved(receipt), at: reviewClock))
		let tryAgain = try next(try sending.answered(.refused(.badRequest), at: reviewClock))
		values = [
			.approval: approval,
			.tryAgain: tryAgain,
			.unconfirmed: try #require(try sending.settled(.readFailed)),
			.blocked: try checking.blocked(.coachOnly),
			.checking: checking,
			.sending: sending,
			.checkingAfterWork: checkingAfterWork,
			.sendingLast: sendingLast,
			.unconfirmedUpgraded: upgraded,
			.completed: completed,
			.canceled: try upgraded.canceled(),
		]
		self.receipt = receipt
	}

	subscript(_ stage: ReviewStage) -> WorkoutReview {
		get throws { try #require(values[stage]) }
	}
}

func placedChanges(_ review: WorkoutReview) -> [ChangeID] {
	(review.work.finished.map(\.change) + review.work.remaining + review.stage.changes).map(\.id)
}

struct UnexpectedReview: Error {
	let detail: String
}

func next(_ step: AnswerStep) throws -> WorkoutReview {
	guard case .next(let review) = step else {
		throw UnexpectedReview(detail: "the answer asked for a read first")
	}
	return review
}
