import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct FixtureResetAdmissionTests {
	@Test func slashStartClearsTheDraftAndFreesSendWhileAReplyWaits() async throws {
		let fixture = AppTestFixture.active
		let services = try fixtureServices(fixture.launch, defaults: fixture.defaults)
		let model = fixtureModel(environment: AppEnvironment(
			services: services, language: .en, defaults: fixture.defaults))
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:hang"
		await model.send()
		try await until {
			if case .processing? = model.chat?.turns.first?.state { return true }
			return false
		}
		model.draft = Draft(id: DraftID(), text: "/start")
		let sending = Task { await model.send() }
		defer { sending.cancel() }
		let deadline = ContinuousClock.now + Duration.seconds(1)
		while model.isSending || !model.draft.text.isEmpty, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(model.draft.text.isEmpty, "The accepted /start must clear the draft while the reply waits")
		#expect(!model.isSending, "Send must be free while New conversation waits")
		model.draft = Draft(id: DraftID(), text: "Remember Saturdays")
		await model.send()
		#expect(model.draft.text.isEmpty)
		await model.stop()
		await sending.value
	}

	private func until(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while !condition(), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		try #require(condition())
	}
}
