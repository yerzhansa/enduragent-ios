import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct FixtureResetAdmissionTests {
	@Test(arguments: [false, true])
	func slashStartClearsTheDraftAndFreesSendWhileAReplyWaits(toolbar: Bool) async throws {
		let fixture = AppTestFixture.active
		let services = try fixtureServices(fixture.launch, defaults: fixture.defaults)
		let model = fixtureModel(
			environment: AppEnvironment(
				services: services, language: .en, defaults: fixture.defaults))
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:hang"
		await model.send()
		try await until {
			if case .processing? = model.chat?.turns.first?.state { return true }
			return false
		}
		model.draft = Draft(id: DraftID(), text: "/start")
		let sending = Task {
			if toolbar { await model.newConversation() } else { await model.send() }
		}
		defer { sending.cancel() }
		let admissionLimit = TestWaitLimit.subject(.seconds(1))
		let deadline = ContinuousClock.now + admissionLimit.duration
		while model.isSending || !model.draft.text.isEmpty, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(
			model.draft.text.isEmpty,
			"The accepted /start must clear the draft while the reply waits")
		#expect(!model.isSending, "Send must be free while New conversation waits")
		model.draft = Draft(id: DraftID(), text: "Remember Saturdays")
		await model.send()
		#expect(model.draft.text.isEmpty)
		await model.stop()
		await sending.value
		try await until {
			model.chat?.opening.showsWelcome == true
				&& model.chat?.turns.contains { $0.athleteText == "Remember Saturdays" } == true
		}
	}

	@Test func aFailedAdmissionKeepsTheSubmittedDraft() async throws {
		let model = try await readyModel()
		await model.services.coach.lifecycle(.willTerminate)
		model.draft = Draft(id: DraftID(), text: "/start")
		let submitted = model.draft
		await model.send()
		#expect(model.draft == submitted)
		#expect(!model.isSending)
		#expect(model.newConversationUncertain)
	}

	@Test func anEditedDraftSurvivesResetAdmission() async throws {
		let model = try await readyModel()
		model.draft = Draft(id: DraftID(), text: "/start")
		let sending = Task { await model.send() }
		await Task.yield()
		try #require(model.isSending)
		model.draft.text = "And on Sunday?"
		model.draftChanged(from: "/start")
		await sending.value
		#expect(model.draft.text == "And on Sunday?")
		#expect(model.drafts.load(.main) == model.draft)
		#expect(!model.isSending)
	}

	@Test func aLaterBoundaryFailureShowsTheObservedNotice() async throws {
		let model = try await readyModel()
		model.draft = Draft(id: DraftID(), text: "fixture:hang")
		await model.send()
		try await until {
			if case .processing? = model.chat?.turns.first?.state { return true }
			return false
		}
		let old = try #require(model.chat?.turns.first?.id)
		try #require(model.services.fixtureRecordFaults).failAppends(ofKind: "windowStart")
		model.draft = Draft(id: DraftID(), text: "/start")
		await model.send()
		#expect(!model.newConversationUncertain)
		#expect(model.draft.text.isEmpty)
		await model.stop()
		try await until { model.newConversationUncertain }
		#expect(model.chat?.turns.map(\.id) == [old])
		#expect(model.chat?.opening == .continuing)
	}

	private func readyModel() async throws -> ShellModel {
		let fixture = AppTestFixture.active
		let services = try fixtureServices(fixture.launch, defaults: fixture.defaults)
		let model = fixtureModel(
			environment: AppEnvironment(
				services: services, language: .en, defaults: fixture.defaults))
		await model.agreeAndStartChatting()
		try await until { model.chat != nil }
		return model
	}

	private func until(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while !condition(), ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		try #require(condition())
	}
}
