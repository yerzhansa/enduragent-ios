import EnduragentCoach
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	func presentedReview(on model: ShellModel, connect: Bool = true) async throws
		-> ReviewControlToken
	{
		if connect {
			model.trainingSettings.edit()
			model.connectKey = "fixture"
			await model.connect()
			try #require(model.didConnect)
		}
		model.draft.text = TutorialCopy.rideRequest
		await model.send()
		try await until { model.chat?.review != nil }
		let review = try #require(model.chat?.review)
		await model.decide(.presented(review.ref))
		try await until { model.chat?.review?.controls != ReviewControls.none }
		return try #require(model.chat?.review?.controls.approveToken)
	}

	func approvalIsBlockedForTheChangedAthlete(
		on model: ShellModel, using token: ReviewControlToken
	)
		async throws
	{
		await model.decide(.approve(token))
		#expect(model.reviewNotice?.key == Catalog.reviewAccountChanged)
		try await until { model.chat?.review.map { $0.ref != token.ref } == true }
		let blocked = try #require(model.chat?.review)
		#expect(blocked.ref.review == token.ref.review)
		await model.decide(.presented(blocked.ref))
		try await until {
			if case .armed(.cancelOnly, _)? = model.chat?.review?.controls { return true }
			return false
		}
	}
}

extension ReviewControls {
	var approveToken: ReviewControlToken? {
		guard case .armed(.approveOrCancel, let token) = self else { return nil }
		return token
	}
}
