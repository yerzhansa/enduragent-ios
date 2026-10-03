import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct TrainingSettingsTests {
	let harness = FixtureLaunchTests()

	@Test func persistenceAndCancelledReplacementKeepConversationHistoryAndPreferences()
		async throws
	{
		let connection: IntervalsConnection
		let turns: [TurnView]
		let history: HistoryList
		let draft: Draft
		do {
			let services = try harness.services()
			let model = await harness.model(services)
			model.continueNotice()
			model.connectKey = "fixture"
			await model.connect()
			try #require(model.didConnect)
			model.continueConnect()
			await model.agreeAndStartChatting()
			try await harness.observed(model)
			await model.chooseLanguage(.fixed(.fr))
			try await model.waitForStatus { $0.language == .fixed(.fr) }
			model.draft.text = TutorialCopy.weekQuestion
			await model.send()
			_ = try await harness.settledTurn(model)
			await model.newConversation()
			try await harness.until { model.chat?.opening.showsWelcome == true }
			await model.loadHistory()
			history = model.history
			model.draft.text = "How did Saturday go"
			await model.send()
			_ = try await harness.settledTurn(model)
			turns = try #require(model.chat?.turns)
			model.draft.text = "Is Thursday still on?"
			model.draftChanged(from: "")
			draft = model.draft
			connection = try #require(try services.fixture?.secrets.intervalsConnection())
			model.open(.settings)
			model.open(.training)
		}
		let (services, defaults) = try await harness.relaunch(.keep)
		let model = await fixtureModel(
			environment: AppEnvironment(services: services, defaults: defaults))
		try await harness.observed(model)
		model.open(.settings)
		model.open(.training)
		let editor = model.trainingSettings
		editor.edit()
		editor.key = "abandoned-replacement"
		await editor.keep()
		#expect(editor.key.isEmpty)
		editor.edit()
		editor.key = " "
		await editor.replace()
		#expect(editor.receipt?.saveNotice?.key == Catalog.connectErrorBlank)
		#expect(try services.fixture?.secrets.intervalsConnection() == connection)
		await editor.keep()
		#expect(model.navigation == [.settings, .training])
		#expect(model.route == .chat)
		#expect(model.languagePreference == .fixed(.fr))
		#expect(model.draft == draft)
		#expect(model.chat?.turns == turns)
		await model.loadHistory()
		#expect(model.history == history)
		model.navigation.removeAll()
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		_ = try await harness.settledTurn(model, at: 1)
		#expect(try await lastClaim(model) == connectionAccount(connection))
	}

	@Test func replacementFailureRotationAndDisconnectReachNextTurn() async throws {
		let model = try await connectedModel()
		let fixture = try #require(model.services.fixture)
		let previous = try #require(try fixture.secrets.intervalsConnection())
		let identity = try await model.services.coach.creditsIdentity()
		let setup = model.status.setup
		let session = model.status.session
		let editor = model.trainingSettings
		editor.edit()
		editor.key = "fixture-rotated"
		try #require(fixture.secretBacking).failNextWrite = true
		await editor.replace()
		#expect(editor.receipt?.saveNotice?.key == Catalog.connectErrorNotSaved)
		#expect(editor.isEditing)
		#expect(try fixture.secrets.intervalsConnection() == previous)
		try await sendWeek(model, at: 0)
		#expect(try await lastClaim(model) == connectionAccount(previous))
		await editor.replace()
		#expect(editor.receipt?.saveNotice?.key == Catalog.planViewEndedSaved)
		#expect(editor.key.isEmpty)
		let rotated = try #require(try fixture.secrets.intervalsConnection())
		#expect(rotated.id != previous.id)
		#expect(rotated.resolvedAthlete == previous.resolvedAthlete)
		try await sendWeek(model, at: 1)
		#expect(try await lastClaim(model) == connectionAccount(rotated))
		editor.requestDisconnect()
		#expect(try fixture.secrets.intervalsConnection() == rotated)
		await editor.keep()
		#expect(try fixture.secrets.intervalsConnection() == rotated)
		editor.requestDisconnect()
		await editor.confirm()
		try await model.waitForStatus { $0.training == .unconnected }
		#expect(try fixture.secrets.intervalsConnection() == nil)
		#expect(editor.state == .viewing)
		#expect(editor.receipt == .disconnected)
		try await sendWeek(model, at: 2)
		#expect(try await lastClaim(model) == "unconnected")
		#expect(model.chat?.turns.count == 3)
		#expect(try await model.services.coach.creditsIdentity() == identity)
		#expect(model.status.setup == setup)
		#expect(model.status.session == session)
		await model.loadHistory()
		#expect(model.history == .loaded([]))
	}

	@Test func ownerConfirmationKeepsOldReviewUnauthorized() async throws {
		let model = try await connectedModel()
		model.draft.text =
			"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
		await model.send()
		_ = try await harness.settledTurn(model)
		let review = try #require(model.chat?.review)
		await model.decide(.presented(review.ref))
		try await harness.until { model.chat?.review?.controls != ReviewControls.none }
		guard case .approveOrCancel(let token)? = model.chat?.review?.controls else {
			Issue.record("review did not expose its approval control")
			return
		}
		let fixture = try #require(model.services.fixture)
		let previous = try #require(try fixture.secrets.intervalsConnection())
		let editor = model.trainingSettings
		editor.edit()
		editor.key = "other-athlete"
		await editor.replace()
		let ada = try #require(IntervalsAthleteID(rawValue: "i1001"))
		let bo = try #require(IntervalsAthleteID(rawValue: "i2002"))
		#expect(editor.state == .confirmingOwner(apiKey: "other-athlete", current: ada, new: bo))
		#expect(editor.key.isEmpty)
		await editor.keep()
		#expect(try fixture.secrets.intervalsConnection() == previous)
		#expect(model.chat?.review?.controls == .approveOrCancel(token))
		editor.edit()
		editor.key = "other-athlete"
		await editor.replace()
		editor.key = "fixture-rotated"
		await editor.confirm()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training {
				return summary.athleteName == "Bo Lind"
			}
			return false
		}
		try await harness.until { model.chat?.review?.notice?.kind == .accountChanged }
		#expect(
			try fixture.secrets.intervalsConnection()?.resolvedAthlete
				== IntervalsAthleteID(rawValue: "i2002"))
		#expect(model.chat?.review?.controls == ReviewControls.none)
		await model.decide(.approve(token))
		#expect(
			!fixture.intervals.calls.contains {
				if case .createEvent = $0 { return true }
				return false
			})
	}

	@Test(arguments: [true, false])
	func savedDisplayFailuresHaveCorrectionAndRetryRoutes(rejected: Bool) async throws {
		let services = try harness.services()
		let fixture = try #require(services.fixture)
		let profile = try await fixture.intervals.fetchAthlete()
		fixture.intervals.setProfileOutcome(
			.failure(
				IntervalsError(code: "http", details: "unavailable", status: rejected ? 401 : 503)))
		let model = await harness.model(services)
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		model.open(.settings)
		model.open(.training)
		let editor = model.trainingSettings
		editor.edit()
		editor.key = "fixture"
		await editor.replace()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training { return summary.action != nil }
			return false
		}
		#expect(editor.receipt?.saveNotice?.key == Catalog.planViewEndedSaved)
		#expect(editor.key.isEmpty)
		let summary = try #require(model.connected)
		let saved = try #require(try fixture.secrets.intervalsConnection())
		let action = try #require(summary.action)
		if rejected {
			#expect(summary.notice?.key == Catalog.connectErrorRejected)
			await model.performTrainingDisplay(action)
			#expect(editor.isEditing)
			#expect(editor.key.isEmpty)
			await editor.keep()
			#expect(try fixture.secrets.intervalsConnection() == saved)
		} else {
			#expect(summary.notice?.key == Catalog.connectErrorProfileUnavailable)
			fixture.intervals.setProfileOutcome(.success(profile))
			await model.performTrainingDisplay(action)
			try await model.waitForStatus {
				if case .connected(let summary, _) = $0.training {
					return summary.today?.fitness == 42
				}
				return false
			}
			#expect(model.connected?.connectionID == saved.id)
			#expect(try fixture.secrets.intervalsConnection()?.credential == saved.credential)
			#expect(editor.receipt?.saveNotice?.key == Catalog.planViewEndedSaved)
		}
		#expect(model.navigation == [.settings, .training])
	}

	@Test func leavingDuringFailedSaveDoesNotRestoreTheSecretDraft() async throws {
		let model = try await connectedModel()
		let fixture = try #require(model.services.fixture)
		let gate = fixture.intervals.holdNextProfileRead()
		defer { Task { await gate.release() } }
		let editor = model.trainingSettings
		editor.edit()
		editor.key = "fixture-rotated"
		try #require(fixture.secretBacking).failNextWrite = true
		let saving = Task { await editor.replace() }
		defer { saving.cancel() }
		try await gate.waitForRead()
		editor.dismiss()
		#expect(editor.key.isEmpty)
		#expect(editor.isSaving)
		await gate.release()
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while editor.isSaving, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		try #require(!editor.isSaving)
		#expect(editor.key.isEmpty)
		#expect(editor.receipt == nil)
		#expect(editor.state == .viewing)
	}

	@Test func unconnectedCalendarNoticeOpensConnectAboveChat() async throws {
		let model = await harness.model(try harness.services())
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		model.draft.text =
			"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
		await model.send()
		_ = try await harness.settledTurn(model)
		let review = try #require(model.chat?.review)
		await model.decide(.presented(review.ref))
		try await harness.until { model.chat?.review?.controls != ReviewControls.none }
		guard case .approveOrCancel(let token)? = model.chat?.review?.controls else {
			Issue.record("missing approval control")
			return
		}
		await model.decide(.approve(token))
		let notice = try #require(model.reviewNotice)
		#expect(notice.key == Catalog.connectMissing)
		await model.perform(try #require(notice.action))
		#expect(model.route == .chat)
		#expect(model.navigation == [.training])
		#expect(model.trainingSettings.isEditing)
		#expect(model.trainingSettings.key.isEmpty)
		#expect(model.chat?.review?.ref == review.ref)
		#expect(model.chat?.turns.count == 1)
	}

	private func connectedModel() async throws -> ShellModel {
		let model = await harness.model(try harness.services())
		await model.agreeAndStartChatting()
		try await harness.observed(model)
		model.open(.settings)
		model.open(.training)
		model.trainingSettings.edit()
		model.trainingSettings.key = "fixture"
		await model.trainingSettings.replace()
		try await model.waitForStatus {
			if case .connected(let summary, _) = $0.training { return summary.today?.fitness == 42 }
			return false
		}
		return model
	}

	private func sendWeek(_ model: ShellModel, at index: Int) async throws {
		model.draft.text = TutorialCopy.weekQuestion
		await model.send()
		_ = try await harness.settledTurn(model, at: index)
	}

	private func lastClaim(_ model: ShellModel) async throws -> String {
		let snapshot = try await model.services.coach.recordSyncProbe().snapshot()
		return try #require(snapshot.rows.last { $0.kind == "turnClaim" }?.account)
	}

	private func connectionAccount(_ connection: IntervalsConnection) -> String {
		"intervals:\(connection.id.rawValue.uuidString):\(connection.resolvedAthlete?.rawValue ?? "unresolved")"
	}
}
