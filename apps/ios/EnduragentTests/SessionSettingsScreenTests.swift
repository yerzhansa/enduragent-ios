import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test(arguments: [
		(SessionField.historyBudgetRatio, "5", ["5", ""]),
		(.contextWindowOverride, "64000", ["30", "64000"]),
	])
	func eachSessionFieldSavesAloneAndSurvivesARelaunch(
		field: SessionField, text: String, saved: [String]
	) async throws {
		do {
			let model = await model(try services())
			await model.agreeAndStartChatting()
			#expect(sessionTexts(model.status) == ["30", ""])
			model.sessionSettings.edit(field, to: text)
			await model.saveSession()
			try await model.waitForStatus { sessionTexts($0) == saved }
			#expect(!model.sessionSettings.isEditing)
			#expect(model.sessionNotSavedLine == nil)
		}
		let (kept, _) = try await relaunch(.keep)
		#expect(sessionTexts(try await kept.coach.observedStatus()) == saved)
	}

	@Test(arguments: [
		(
			SessionField.historyBudgetRatio, "0", "30", SessionField.contextWindowOverride, "64000",
			"Enter a history budget above 0% and no more than 100%.", ["30", "64000"]
		),
		(
			.contextWindowOverride, "0", "", .historyBudgetRatio, "5",
			"Enter a safe whole number of tokens, 1 or more.", ["5", ""]
		),
	])
	func aRejectedSessionValueShowsItsSentenceAndSavesNeitherField(
		rejected: SessionField, text: String, corrected: String, other: SessionField,
		otherText: String, sentence: String, saved: [String]
	) async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		let session = model.sessionSettings
		session.edit(rejected, to: text)
		session.edit(other, to: otherText)
		await model.saveSession()
		#expect(
			session.rejections.mapValues { $0.sentence(in: model.phrasebook) }
				== [rejected: sentence])
		#expect(session.drafts == [rejected: text, other: otherText])
		#expect(model.sessionNotSavedLine == nil)
		#expect(try await services.coach.observedStatus().session == .npmDefaults)
		#expect(try await sessionRecordCount(services) == 0)
		session.edit(rejected, to: corrected)
		#expect(session.rejections.isEmpty)
		await model.saveSession()
		try await model.waitForStatus { sessionTexts($0) == saved }
		#expect(!session.isEditing)
	}

	@Test func aSessionSaveThatFailsShowsTheNoticeAndKeepsTheSavedValueAndConversation()
		async throws
	{
		let turn: TurnView
		do {
			let services = try services()
			let records = try #require(services.fixtureRecordFaults)
			let model = await model(services)
			await model.agreeAndStartChatting()
			model.draft.text = TutorialCopy.weekQuestion
			await model.send()
			turn = try await settledTurn(model)
			model.sessionSettings.edit(.contextWindowOverride, to: "64000")
			await model.saveSession()
			try await model.waitForStatus { sessionTexts($0) == ["30", "64000"] }
			records.failNextAppend = true
			model.sessionSettings.edit(.historyBudgetRatio, to: "5")
			await model.saveSession()
			#expect(!records.failNextAppend)
			#expect(
				model.sessionNotSavedLine
					== "Couldn't save your choice on this iPhone, so nothing was changed. Try again."
			)
			#expect(model.sessionSettings.drafts == [.historyBudgetRatio: "5"])
			#expect(sessionTexts(try await services.coach.observedStatus()) == ["30", "64000"])
			#expect(try await sessionRecordCount(services) == 1)
			#expect(model.chat?.turns.map(\.id) == [turn.id])
			model.sessionSettings.cancel()
			#expect(model.sessionNotSavedLine == nil)
			#expect(!model.sessionSettings.isEditing)
		}
		let (kept, keptDefaults) = try await relaunch(.keep)
		let reopened = await fixtureModel(
			environment: AppEnvironment(services: kept, defaults: keptDefaults))
		try await observed(reopened)
		try await reopened.waitForStatus { sessionTexts($0) == ["30", "64000"] }
		#expect(reopened.chat?.turns.map(\.id) == [turn.id])
	}

	@Test func cancelLeavesAnUnfinishedSessionEditUnapplied() async throws {
		let services = try services()
		let model = await model(services)
		await model.agreeAndStartChatting()
		model.sessionSettings.edit(.historyBudgetRatio, to: "5")
		model.sessionSettings.edit(.contextWindowOverride, to: "64000")
		#expect(model.sessionSettings.isEditing)
		model.sessionSettings.cancel()
		#expect(!model.sessionSettings.isEditing)
		await model.saveSession()
		#expect(try await services.coach.observedStatus().session == .npmDefaults)
		#expect(try await sessionRecordCount(services) == 0)
	}

	private func sessionTexts(_ status: CoachStatus) -> [String] {
		SessionField.allCases.map { status.session.text(for: $0) }
	}

	private func sessionRecordCount(_ services: AppServices) async throws -> Int {
		try await services.coach.recordSyncProbe().snapshot().counts
			.first { $0.kind == "sessionSettings" }?.count ?? 0
	}
}
