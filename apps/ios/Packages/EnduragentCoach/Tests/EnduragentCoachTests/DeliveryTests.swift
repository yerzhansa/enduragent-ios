import Foundation
import Testing

@testable import EnduragentCoach

struct DeliveryTests {
	static let stages: [ReviewStage] = ReviewStage.allCases

	@Test(arguments: stages)
	func noControlExistsBeforeTheAcknowledgement(_ stage: ReviewStage) throws {
		let review = try ReviewStages()[stage]
		let delivery = Delivery.fresh(for: review, at: reviewULID(601))

		#expect(delivery.controls(review.allowedControls) == ReviewControls.none)
		#expect(delivery.ref.chat == review.chat)
		#expect(delivery.ref.review == review.id)
		#expect(delivery.ref.revision == review.revision)
	}

	@Test(arguments: stages)
	func anAcknowledgedDeliveryArmsTheStagesControls(_ stage: ReviewStage) throws {
		let review = try ReviewStages()[stage]
		let delivery = Delivery.fresh(for: review, at: reviewULID(601)).acknowledge()
		let controls = delivery.controls(review.allowedControls)

		switch (review.allowedControls, controls) {
		case (nil, .none):
			break
		case (let allowed?, .armed(let set, let token)):
			#expect(set == allowed)
			#expect(token.ref == delivery.ref)
			#expect(delivery.admits(token))
		default:
			Issue.record(
				"\(stage) allows \(String(describing: review.allowedControls)), got \(controls)")
		}
	}

	@Test func aTokenFromAnEarlierHeadOrDeliveryIsNotAdmitted() throws {
		let review = try reviewFixture("workout-review-approval")
		let first = Delivery.fresh(for: review, at: reviewULID(601)).acknowledge()
		let token = try #require(armedToken(of: first, review))

		let sameHeadAgain = Delivery.fresh(for: review, at: reviewULID(601)).acknowledge()
		let laterHead = Delivery.fresh(for: review, at: reviewULID(602)).acknowledge()

		#expect(first.admits(token))
		#expect(!sameHeadAgain.admits(token))
		#expect(!laterHead.admits(token))
		#expect(sameHeadAgain.ref != first.ref)
		#expect(laterHead.head == reviewULID(602))
	}

	@Test func aShownDeliveryAdmitsNoTokenAndAcknowledgingTwiceKeepsTheToken() throws {
		let review = try reviewFixture("workout-review-approval")
		let shown = Delivery.fresh(for: review, at: reviewULID(601))
		let armed = shown.acknowledge()
		let token = try #require(armedToken(of: armed, review))

		#expect(!shown.admits(token))
		#expect(armed.acknowledge() == armed)
		#expect(armed.acknowledge().admits(token))
	}

	private func armedToken(of delivery: Delivery, _ review: WorkoutReview) -> ReviewControlToken? {
		guard case .armed(_, let token) = delivery.controls(review.allowedControls) else {
			return nil
		}
		return token
	}
}
