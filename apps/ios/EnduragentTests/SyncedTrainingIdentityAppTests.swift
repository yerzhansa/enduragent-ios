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
		try await until { model.chat?.liveReply?.text == "Still on." }
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
			let profileReads = fixture.intervals.count(of: .profile)
			await model.sceneChanged(.becameActive)
			let rechecked = try #require(await harness.firstSnapshot(services, chat: .main))
			#expect(rechecked.revision == finished.revision)
			#expect(model.chat?.revision == finished.revision)
			#expect(model.chat == finished)
			#expect(model.draft == draft)
			if connected { #expect(fixture.intervals.count(of: .profile) > profileReads) }
		}
	}

	@Test func sceneResumeKeepsAWaitingReviewArmedWhenTheProfileCannotBeRead() async throws {
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
		try await until { model.chat?.review != nil }
		let review = try #require(model.chat?.review)
		await model.decide(.presented(review.ref))
		try await until { model.chat?.review?.controls.isApproveOrCancel == true }
		let finished = try #require(model.chat)
		model.draft.text = "What about Friday?"
		let draft = model.draft
		fixture.intervals.fail(.profile, with: URLError(.notConnectedToInternet))
		for background in [true, false] {
			if background { await model.sceneChanged(.enteredBackground) }
			let profileReads = fixture.intervals.count(of: .profile)
			await model.sceneChanged(.becameActive)
			try await model.waitForStatus {
				$0.training.notice?.key == Catalog.connectErrorProfileUnavailable
			}
			let rechecked = try #require(await harness.firstSnapshot(services, chat: .main))
			#expect(rechecked.turns == finished.turns)
			#expect(rechecked.review?.ref == review.ref)
			#expect(rechecked.review?.controls.isApproveOrCancel == true)
			#expect(rechecked.review?.notice == nil)
			#expect(rechecked.revision == finished.revision)
			#expect(model.chat?.revision == finished.revision)
			#expect(model.draft == draft)
			#expect(fixture.intervals.count(of: .profile) > profileReads)
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
		try await until { model.chat?.review != nil }
		let presented = try #require(model.chat?.review)
		await model.decide(.presented(presented.ref))
		let original = try #require(model.chat?.review)
		await model.sceneChanged(.enteredBackground)
		try fixture.trainingPeer.replace(.athleteB)
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.training.athleteName == "Bo Lind" }
		#expect(model.connected?.athleteName == "Bo Lind")
		#expect(model.chat?.review?.ref.review == original.ref.review)
		let token = try #require(model.chat?.review?.controls.approveToken)
		try await harness.approvalIsBlockedForTheChangedAthlete(on: model, using: token)
		try fixture.trainingPeer.delete()
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus { $0.training == .unconnected }
		#expect(model.connected == nil)
		#expect(model.chat?.review?.ref.review == original.ref.review)
		#expect(fixture.trainingPeer.athleteA.events.isEmpty)
		#expect(fixture.trainingPeer.athleteB.events.isEmpty)
	}
}

extension ReviewControls {
	fileprivate var isApproveOrCancel: Bool { approveToken != nil }
}

extension TrainingStatus {
	fileprivate var athleteName: String? {
		guard case .connected(let summary, _) = self else { return nil }
		return summary.athleteName
	}
}
