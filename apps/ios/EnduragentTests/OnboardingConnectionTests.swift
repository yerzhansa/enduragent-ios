import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct OnboardingConnectionTests {
	let harness = FixtureLaunchTests()

	@Test(arguments: FixtureTrainingDisplay.allCases)
	func savedResultAndDisplayRecoveryUseTheOnboardingEntryPoint(display: FixtureTrainingDisplay)
		async throws
	{
		var launch = harness.launch
		launch.trainingDisplay = display
		let services = try fixtureServices(launch, defaults: harness.defaults)
		let fixture = try #require(services.fixture)
		let model = await harness.model(services)
		await model.appear()
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		try await model.waitForStatus {
			guard case .connected(let summary, _) = $0.training else { return false }
			return !summary.needsReadForProof
		}
		#expect(model.route == .onboarding(.connect))
		#expect(model.didConnect)
		#expect(model.connectKey.isEmpty)
		#expect(model.trainingSettings.receipt?.saveNotice?.key == Catalog.planViewEndedSaved)
		let summary = try #require(model.connected)
		let saved = try #require(try fixture.secrets.intervalsConnection())
		switch display {
		case .profileRejected, .profileRequestRejected, .profileUnavailable:
			#expect(summary.athleteName == nil)
			#expect(summary.today == nil)
		case .wellnessRejected, .wellnessUnavailable, .emptyWellness, .partialWellness:
			#expect(summary.athleteName == "Ada Kovač")
		}
		switch display {
		case .profileRejected:
			#expect(summary.notice?.key == Catalog.connectErrorRejected)
		case .profileRequestRejected:
			#expect(summary.notice?.key == Catalog.coachErrorIntervalsCredentials)
		case .profileUnavailable:
			#expect(summary.notice?.key == Catalog.connectErrorProfileUnavailable)
		case .wellnessRejected:
			#expect(summary.notice?.key == Catalog.connectErrorWellnessRejected)
			#expect(summary.today == nil)
		case .wellnessUnavailable:
			#expect(summary.notice?.key == Catalog.connectErrorWellnessUnavailable)
			#expect(summary.today == nil)
		case .emptyWellness:
			#expect(summary.wellness == .available(.noData(on: "1998-06-15")))
			#expect(summary.notice?.key == Catalog.connectWellnessEmpty)
		case .partialWellness:
			#expect(summary.today?.fitness == 42)
			#expect(summary.today?.fatigue == nil)
			#expect(summary.today?.form == nil)
			#expect(summary.notice == nil)
		}
		switch display {
		case .emptyWellness, .partialWellness:
			#expect(summary.action == nil)
		case .profileRejected, .profileRequestRejected, .profileUnavailable,
			.wellnessRejected, .wellnessUnavailable:
			let action = try #require(summary.action)
			await model.performTrainingDisplay(action)
			switch action {
			case .reviewConnection:
				#expect(model.trainingSettings.isEditing)
				#expect(model.connectKey.isEmpty)
				model.connectKey = "fixture-corrected"
				await model.connect()
			case .retry:
				#expect(try fixture.secrets.intervalsConnection()?.id == saved.id)
				#expect(try fixture.secrets.intervalsConnection()?.credential == saved.credential)
			}
			try await model.waitForStatus {
				guard case .connected(let summary, _) = $0.training else { return false }
				return summary.today?.form == -7
			}
			#expect(model.connected?.notice == nil)
			#expect(model.trainingSettings.receipt?.saveNotice?.key == Catalog.planViewEndedSaved)
		}
		model.continueConnect()
		#expect(model.route == .onboarding(.starter))
		#expect(model.connectKey.isEmpty)
	}

	@Test func failedWriteKeepsThePreviousConnectionAvailableToContinue() async throws {
		let services = try harness.services()
		let fixture = try #require(services.fixture)
		let model = await harness.model(services)
		await model.appear()
		model.continueNotice()
		model.connectKey = "fixture"
		await model.connect()
		try await model.waitForStatus {
			guard case .connected(let summary, _) = $0.training else { return false }
			return summary.today?.fitness == 42
		}
		let previous = try #require(try fixture.secrets.intervalsConnection())
		model.connectKey = "fixture-rotated"
		fixture.secretBacking.failNextWrite = true
		await model.connect()
		#expect(model.trainingSettings.receipt?.saveNotice?.key == Catalog.connectErrorNotSaved)
		#expect(model.trainingSettings.isEditing)
		#expect(model.didConnect)
		#expect(try fixture.secrets.intervalsConnection() == previous)
		model.continueConnect()
		#expect(model.route == .onboarding(.starter))
		await model.agreeAndStartChatting()
		model.draft.text = FirstWeekFixture.trainingDataDirective
		await model.send()
		#expect(
			replyText(try await harness.settledTurn(model).state)
				== "I can read Ada Kovač's training profile and calendar.")
		let records = try await services.coach.recordSyncProbe().snapshot()
		#expect(
			records.rows.last { $0.kind == "turnClaim" }?.account
				== "intervals:\(previous.id.rawValue.uuidString):i1001")
	}
}

extension IntervalsSummary {
	fileprivate var needsReadForProof: Bool {
		if profile == .waiting { return true }
		if case .available(let profile) = profile { return profile.wellness == .waiting }
		return false
	}
}
