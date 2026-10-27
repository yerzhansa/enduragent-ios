import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

enum BoundHead: String, CaseIterable, CustomTestStringConvertible {
	case none, preparing, waiting, claimed, sending, unconfirmed, completed, canceled,
		canceledUnconfirmed

	var testDescription: String { rawValue }

	var holds: Bool {
		switch self {
		case .preparing, .waiting, .claimed, .sending, .unconfirmed: true
		case .none, .completed, .canceled, .canceledUnconfirmed: false
		}
	}

	func save(in rig: DeskRig, desk: WorkoutReviewDesk) async throws {
		let review = try PreflightFixture.review([
			PreflightFixture.ride(on: "1998-09-09", identity: CalendarWriteID()),
			rig.strength(on: "1998-09-12"),
		])
		let claimed = try review.claimed(
			Claim(id: ClaimID(ulid: reviewULID(803)), action: .approve))
		let sending = try claimed.sending(at: rig.clock.now, seen: [:])
		guard case .readFirst = try sending.answered(.lost(.transport), at: rig.clock.now),
			let unconfirmed = try sending.settled(.readFailed)
		else {
			throw UnexpectedReview(
				detail: "a lost answer and a failed read left no unconfirmed change")
		}
		switch self {
		case .none:
			break
		case .preparing:
			let request = try PreparationFixture.request(ReviewTurns.oneRide, today: DeskRig.today)
			guard
				case .drafted = await desk.prepare(
					.success(request), for: PreparationFixture.key, chat: .main,
					binding: testStamp(account: PreflightFixture.account).binding,
					reads: rig.calendar)
			else {
				throw UnexpectedReview(detail: "the preparation did not draft")
			}
		case .waiting: try await rig.save(review)
		case .claimed: try await rig.save(claimed)
		case .sending: try await rig.save(sending)
		case .unconfirmed: try await rig.save(unconfirmed)
		case .completed:
			try await rig.save(
				try claimed.sending(
					at: rig.clock.now,
					seen: Dictionary(
						uniqueKeysWithValues: review.work.remaining.map {
							($0.id, EventID(rawValue: 204))
						})))
		case .canceled: try await rig.save(try review.canceled())
		case .canceledUnconfirmed: try await rig.save(try unconfirmed.canceled())
		}
	}
}
