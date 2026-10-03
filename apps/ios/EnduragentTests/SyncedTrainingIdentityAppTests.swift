import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct SyncedTrainingIdentityAppTests {
	@Test(arguments: [false, true])
	func sceneResumeKeepsScrollRevisionUnlessAReplyFinished(connected: Bool) async throws {
		let harness = FixtureLaunchTests()
		let services = try harness.services()
		let fixture = try #require(services.fixture)
		let model = await harness.model(services)
		await model.agreeAndStartChatting()
		if connected {
			try fixture.trainingPeer.replace(.athleteA)
			await model.sceneChanged(.becameActive)
			try await model.waitForStatus { $0.training.athleteName == "Ada Kovač" }
		}
		fixture.transport.respond = { _ in
			ScriptedReply([.text("Still on."), .finish(reason: .stop)], deltaDelay: .seconds(2))
		}
		model.draft.text = "Is Thursday still on?"
		await model.send()
		await model.sceneChanged(.enteredBackground)
		try await harness.until { model.chat?.liveReply?.text == "Still on." }
		let running = try #require(model.chat)
		try #require(running.turns.last?.state.isSettled == false)
		let turn = try await harness.settledTurn(model)
		let finished = try #require(model.chat)
		#expect(replyText(turn.state) == "Still on.")
		#expect(turn.completedInBackground)
		#expect(finished.revision == running.revision + 1)
		model.draft.text = "What about Friday?"
		let draft = model.draft
		for background in [false, true, false] {
			if background { await model.sceneChanged(.enteredBackground) }
			let profileReads = fixture.intervals.profileReadCount
			await model.sceneChanged(.becameActive)
			let rechecked = try #require(await harness.firstSnapshot(services, chat: .main))
			#expect(rechecked.revision == finished.revision)
			#expect(model.chat?.revision == finished.revision)
			#expect(model.chat == finished)
			#expect(model.draft == draft)
			if connected { #expect(fixture.intervals.profileReadCount > profileReads) }
		}
	}

	@Test func sceneResumePublishesPeerIdentityAndDeletion() async throws {
		let harness = FixtureLaunchTests()
		let services = try harness.services()
		let fixture = try #require(services.fixture)
		let model = await harness.model(services)
		await model.agreeAndStartChatting()
		try fixture.trainingPeer.replace(.athleteA)
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.training.athleteName == "Ada Kovač" }
		model.draft.text = "Give me an endurance ride for tomorrow"
		await model.send()
		_ = try await harness.settledTurn(model)
		try await harness.until { model.chat?.review != nil }
		let presented = try #require(model.chat?.review)
		await model.decide(.presented(presented.ref))
		let original = try #require(model.chat?.review)
		await model.sceneChanged(.enteredBackground)
		try fixture.trainingPeer.replace(.athleteB)
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.training.athleteName == "Bo Lind" }
		try await harness.until { model.chat?.review?.notice?.key == Catalog.reviewAccountChanged }
		#expect(model.connected?.athleteName == "Bo Lind")
		#expect(model.athleteFirstName == "Bo")
		#expect(model.chat?.review?.ref.set == original.ref.set)
		#expect(model.chat?.review?.controls == ReviewControls.none)
		try fixture.trainingPeer.delete()
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.training == .unconnected }
		#expect(model.connected == nil)
		#expect(model.athleteFirstName.isEmpty)
		#expect(model.chat?.review?.ref.set == original.ref.set)
		#expect(fixture.trainingPeer.athleteA.events.isEmpty)
		#expect(fixture.trainingPeer.athleteB.events.isEmpty)
	}

	@Test func foregroundPeerReplacementIsCheckedBySendAndApproval() async throws {
		let harness = FixtureLaunchTests()
		let services = try harness.services()
		let fixture = try #require(services.fixture)
		let model = await harness.model(services)
		await model.agreeAndStartChatting()
		try fixture.trainingPeer.replace(.athleteA)
		await model.sceneChanged(.becameActive)
		model.draft.text = "Give me an endurance ride for tomorrow"
		await model.send()
		_ = try await harness.settledTurn(model)
		try await harness.until { model.chat?.review != nil }
		let presented = try #require(model.chat?.review)
		await model.decide(.presented(presented.ref))
		try await harness.until {
			if case .approveOrCancel? = model.chat?.review?.controls { return true }
			return false
		}
		guard case .approveOrCancel(let token)? = model.chat?.review?.controls else {
			Issue.record("The review did not offer approval")
			return
		}
		try fixture.trainingPeer.replace(.athleteB)
		await model.decide(.approve(token))
		try await model.waitForStatus { $0.training.athleteName == "Bo Lind" }
		try await harness.until { model.chat?.review?.notice?.key == Catalog.reviewAccountChanged }
		#expect(model.chat?.review?.notice?.key == Catalog.reviewAccountChanged)
		#expect(model.chat?.review?.controls == ReviewControls.none)
		#expect(fixture.trainingPeer.athleteB.events.isEmpty)
		model.draft.text = FirstWeekFixture.trainingDataDirective
		await model.send()
		let turn = try await harness.settledTurn(model, at: 1)
		#expect(replyText(turn.state) == "I can read Bo Lind's training profile and calendar.")
		try fixture.trainingPeer.replace(.unavailable)
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus {
			$0.training.notice?.key == Catalog.connectErrorProfileUnavailable
		}
		try await harness.until { model.chat?.review?.notice?.key == Catalog.reviewCannotVerify }
		#expect(model.chat?.review?.ref.set == token.ref.set)
		#expect(model.chat?.review?.controls == ReviewControls.none)
		#expect(model.chat?.review?.notice?.key == Catalog.reviewCannotVerify)
		#expect(
			try fixture.secrets.intervalsConnection()?.credential
				== .apiKey(FixtureTrainingPeer.Key.unavailable.secret))
		#expect(fixture.trainingPeer.athleteA.events.isEmpty)
		#expect(fixture.trainingPeer.athleteB.events.isEmpty)
	}
}

extension TrainingStatus {
	fileprivate var athleteName: String? {
		guard case .connected(let summary, _) = self else { return nil }
		return summary.athleteName
	}
}
