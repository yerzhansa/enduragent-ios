import EnduragentCoach
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func recordReadLaunchHookWaitsForAPresentedSettledReviewAndFailsOnce() async throws {
		var configured = launch
		configured.recordReadFault = .failAfterPresentedOnce
		let services = try AppServices.fixture(configured, defaults: defaults)
		let model = model(services)
		await model.agreeAndStartChatting()
		model.connectKey = "fixture"
		await model.connect()
		try #require(model.didConnect)
		model.draft.text =
			"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
		await model.send()
		_ = try await settledTurn(model)
		try await until { model.chat?.review != nil }
		let unpresented = try #require(model.chat?.review)
		#expect(unpresented.notice == nil)
		#expect(unpresented.controls == .none)
		await model.decide(.presented(unpresented.ref))
		try await until { model.chat?.review?.notice?.key == Catalog.reviewStorageUnavailable }
		let failed = try #require(model.chat?.review)
		#expect(failed.ref == unpresented.ref)
		#expect(failed.cards == unpresented.cards)
		#expect(failed.controls == .none)
		await model.decide(.checkAgain(failed.ref))
		try await until {
			if case .approveOrCancel? = model.chat?.review?.controls { return true }
			return false
		}
		#expect(model.chat?.review?.notice == nil)
		await model.decide(.presented(failed.ref))
		#expect(model.chat?.review?.notice == nil)
	}
}
