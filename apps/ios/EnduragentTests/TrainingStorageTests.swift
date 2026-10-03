import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct TrainingStorageTests {
	let harness = FixtureLaunchTests()

	@Test(arguments: [FixtureKeychainPolicy.unlocked, .locked, .unavailable, .malformedIntervals])
	func storageGuidanceRoutesThroughShellAndKeepsSavedConversation(policy: FixtureKeychainPolicy)
		async throws
	{
		let turns: [TurnView]
		do {
			let services = try harness.services()
			let model = await harness.model(services)
			await model.appear()
			model.continueNotice()
			if policy == .unlocked {
				model.skipConnect()
			} else {
				model.connectKey = "fixture"
				await model.connect()
				model.continueConnect()
			}
			await model.agreeAndStartChatting()
			try await harness.observed(model)
			model.draft.text = "Remember that I ride with a group on Saturdays"
			await model.send()
			_ = try await harness.settledTurn(model)
			turns = try #require(model.chat?.turns)
		}
		let (reopenedServices, defaults) = try await harness.relaunch(.keep, keychain: policy)
		let reopened = await fixtureModel(
			environment: AppEnvironment(
				services: reopenedServices, defaults: defaults))
		try await harness.observed(reopened)
		reopened.open(.settings)
		reopened.open(.training)
		#expect(reopened.route == .chat)
		#expect(reopened.chat?.turns == turns)
		#expect(reopened.navigation == [.settings, .training])
		let training = reopened.status.training
		let fixture = try #require(reopenedServices.fixture)
		let notice = try #require(training.notice)
		switch policy {
		case .unlocked:
			#expect(notice.key == Catalog.connectMissing)
			#expect(training.connectionActionTitle == Catalog.onboardingConnectAction)
			#expect(notice.action == .connectTraining)
			reopened.trainingSettings.edit()
			#expect(reopened.trainingSettings.key.isEmpty)
		case .locked, .unavailable:
			#expect(
				notice.key
					== (policy == .locked
						? Catalog.connectErrorStorageLocked
						: Catalog.connectErrorStorageUnavailable))
			#expect(training.connectionActionTitle == nil)
			let retry = try #require(training.action)
			#expect(retry == .retryStorage)
			try #require(fixture.secretBacking).locked = false
			try #require(fixture.secretBacking).unavailable = false
			await reopened.performTrainingDisplay(retry)
			try await reopened.waitForStatus {
				guard case .connected(let summary, _) = $0.training else { return false }
				return summary.today?.fitness == 42
			}
			#expect(reopened.status.notice == nil)
			#expect(reopened.status.training.notice == nil)
		case .malformedIntervals:
			#expect(notice.key == Catalog.connectErrorStorageMalformed)
			#expect(training.connectionActionTitle == Catalog.settingsTrainingReplace)
			reopened.navigation.removeAll()
			reopened.draft.text = "Read my training"
			await reopened.send()
			let failed = try await harness.settledTurn(reopened, at: 1)
			guard case .failed(let result) = failed.state else {
				Issue.record("The malformed training item did not produce a correction notice")
				return
			}
			#expect(result.notice.key == Catalog.connectErrorStorageMalformed)
			await reopened.perform(try #require(result.notice.action))
			#expect(reopened.route == .chat)
			#expect(reopened.navigation == [.training])
			#expect(reopened.trainingSettings.isEditing)
			#expect(reopened.trainingSettings.key.isEmpty)
			await reopened.trainingSettings.keep()
			#expect(reopened.trainingSettings.state == .viewing)
			#expect(reopened.status.training == training)
			reopened.trainingSettings.edit()
			reopened.trainingSettings.key = "fixture-corrected"
			await reopened.trainingSettings.replace()
			try await reopened.waitForStatus {
				guard case .connected(let summary, _) = $0.training else { return false }
				return summary.today?.fitness == 42
			}
			#expect(
				reopened.trainingSettings.receipt?.saveNotice?.key == Catalog.planViewEndedSaved)
			#expect(reopened.trainingSettings.key.isEmpty)
		case .empty, .nativeProof:
			Issue.record("This matrix covers training storage, not missing model access")
		}
		#expect(reopened.route == .chat)
		#expect(reopened.chat?.turns.first == turns.first)
		#expect(!notice.sentence(in: reopened.displayLocale).contains("fixture-malformed-secret"))
	}
}
