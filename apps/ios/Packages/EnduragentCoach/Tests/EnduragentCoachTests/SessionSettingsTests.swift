import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SessionSettingsTests {
	private let english = CatalogPhrasebook(tag: .en)

	@Test func defaultsMatchNpm() {
		let defaults = SessionSettings.npmDefaults
		#expect(defaults.historyBudgetRatio.value == 0.3)
		#expect(defaults.contextWindowOverride == nil)
		#expect(
			SessionField.allCases.map { defaults.text(for: $0) } == ["0.3", ""])
	}

	@Test(arguments: [
		(
			SessionField.historyBudgetRatio, "0",
			"Enter a history budget above 0% and no more than 100%."
		),
		(.historyBudgetRatio, "1.5", "Enter a history budget above 0% and no more than 100%."),
		(.historyBudgetRatio, "nan", "Enter a history budget above 0% and no more than 100%."),
		(.historyBudgetRatio, "inf", "Enter a history budget above 0% and no more than 100%."),
		(.historyBudgetRatio, "abc", "Enter a history budget above 0% and no more than 100%."),
		(.contextWindowOverride, "0", "Enter a safe whole number of tokens, 1 or more."),
		(.contextWindowOverride, "-1", "Enter a safe whole number of tokens, 1 or more."),
		(.contextWindowOverride, "1.5", "Enter a safe whole number of tokens, 1 or more."),
		(
			.contextWindowOverride, "9007199254740992",
			"Enter a safe whole number of tokens, 1 or more."
		),
		(.contextWindowOverride, "abc", "Enter a safe whole number of tokens, 1 or more."),
	])
	func eachFieldRejectsItsInvalidValue(field: SessionField, text: String, sentence: String)
		async throws
	{
		let store = InMemoryRecordLog()
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		let stored = try SessionSettings.npmDefaults.replacing(.historyBudgetRatio, with: "0.05")
			.replacing(.contextWindowOverride, with: "64000")
		try await coach.setSession(stored)
		do {
			try await coach.setSession(stored.replacing(field, with: text))
			Issue.record("\(field) accepted \(text)")
		} catch let error as SessionSettingRejected {
			#expect(error.field == field)
			#expect(error.sentence(in: english) == sentence)
		}
		#expect(try await coach.observedStatus().session == stored)
		await coach.lifecycle(.willTerminate)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: store)
		#expect(try await reopened.observedStatus().session == stored)
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.sessionSettings]))).records.count
				== 1)
		await reopened.lifecycle(.willTerminate)
	}

	@Test func validValuesReplaceOnlyTheirField() throws {
		var settings = SessionSettings.npmDefaults
		settings = try settings.replacing(.historyBudgetRatio, with: "0.05")
		settings = try settings.replacing(.contextWindowOverride, with: "64000")
		#expect(settings.historyBudgetRatio.value == 0.05)
		#expect(settings.contextWindowOverride?.tokens == 64_000)
		let cleared = try settings.replacing(.contextWindowOverride, with: " ")
		#expect(cleared.contextWindowOverride == nil)
	}

	@Test(arguments: [AccessMethod.credits, .openRouterAccount])
	func setSessionStoresOneRecordThatTheNextCoachReads(_ method: AccessMethod) async throws {
		let store = InMemoryRecordLog()
		let secrets = keyedSecrets()
		if method == .openRouterAccount {
			try secrets.installOpenRouterChoice(
				model: ModelID(rawValue: "test/account-model"), key: "synthetic-session-account")
		}
		let transport = FakeModelTransport(respond: { _ in
			ScriptedReply([.text("Your conversation stays here."), .finish(reason: .stop)])
		})
		var coach = await makeCoach(transport: transport, store: store, secrets: secrets)
		await coach.lifecycle(.becameActive)
		#expect(try await coach.observedStatus().session == .npmDefaults)
		try await coach.setLanguage(.fixed(.fr))
		#expect(
			replyText(try await coach.sendAndSettle("Keep this conversation"))
				== "Your conversation stays here.")
		let original = try await coach.observedStatus()
		#expect(original.access.selection?.method == method)
		#expect(original.setup == .ready)
		#expect(original.trainingAccount == testConnection.account)
		let conversation = try await snapshot(of: coach)
		#expect(conversation.turns.count == 1)
		let edits: [(SessionField, String, Double, Int?)] = [
			(.contextWindowOverride, "64000", 0.3, 64_000),
			(.historyBudgetRatio, "0.05", 0.05, 64_000),
			(.contextWindowOverride, "32000", 0.05, 32_000),
			(.contextWindowOverride, " ", 0.05, nil),
		]
		for (index, edit) in edits.enumerated() {
			let settings = try await coach.observedStatus().session.replacing(edit.0, with: edit.1)
			try await coach.setSession(settings)
			for reopening in [false, true] {
				if reopening {
					await coach.lifecycle(.willTerminate)
					coach = await makeCoach(
						transport: transport, store: store, secrets: secrets, consent: false)
					await coach.lifecycle(.becameActive)
				}
				let status = try await coach.observedStatus()
				#expect(status.session.historyBudgetRatio.value == edit.2)
				#expect(status.session.contextWindowOverride?.tokens == edit.3)
				#expect(status.access == original.access)
				#expect(status.training == original.training)
				#expect(status.language == .fixed(.fr))
				#expect(try await snapshot(of: coach) == conversation)
			}
			#expect(
				try await store.fetch(RecordQuery(scope: .synced([.sessionSettings]))).records.count
					== index + 1)
		}
		await coach.lifecycle(.willTerminate)
	}

	@Test func failedSessionWriteKeepsTheStoredSettings() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let transport = FakeModelTransport(respond: { _ in
			ScriptedReply([.text("Your settings stay saved."), .finish(reason: .stop)])
		})
		let coach = await makeCoach(transport: transport, store: log)
		let stored = try SessionSettings.npmDefaults.replacing(.historyBudgetRatio, with: "0.05")
			.replacing(.contextWindowOverride, with: "64000")
		try await coach.setSession(stored)
		#expect(
			replyText(try await coach.sendAndSettle("Keep my saved settings"))
				== "Your settings stay saved.")
		let conversation = try await snapshot(of: coach)
		try log.failAppends(ofKind: "sessionSettings")
		for (field, text) in [
			(SessionField.historyBudgetRatio, "0.5"), (.contextWindowOverride, "32000"),
		] {
			await #expect(throws: PreferenceWriteFailure.notSaved) {
				try await coach.setSession(stored.replacing(field, with: text))
			}
			#expect(try await coach.observedStatus().session == stored)
			#expect(try await snapshot(of: coach) == conversation)
		}
		await coach.lifecycle(.willTerminate)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: log, consent: false)
		#expect(try await reopened.observedStatus().session == stored)
		#expect(try await snapshot(of: reopened) == conversation)
		#expect(
			try await log.fetch(RecordQuery(scope: .synced([.sessionSettings]))).records.count == 1)
		await reopened.lifecycle(.willTerminate)
	}

	@Test func storedValuesOutsideTheirRangeDecodeAsMalformedRows() {
		let ratio = Data(
			#"{"compactionModel":"","flushModel":"","historyBudgetRatio":1.5}"#.utf8)
		#expect(
			RecordCodec.decode(
				kind: "sessionSettings", version: 2, data: ratio, civilDate: "1998-06-13",
				ulid: "row-ratio")
				== .failure(.malformed(kind: "sessionSettings", ulid: "row-ratio")))
		let tag = Data(#"{"tag":"xx"}"#.utf8)
		#expect(
			RecordCodec.decode(
				kind: "languagePreference", version: 2, data: tag, civilDate: "1998-06-13",
				ulid: "row-tag")
				== .failure(.malformed(kind: "languagePreference", ulid: "row-tag")))
	}

	@Test(arguments: [1, 2])
	func aStoredRowWithRetiredResetKeysKeepsItsOtherSettings(_ version: Int) async throws {
		let payload =
			#"{"archiveRetentionDays":14,"compactionModel":"test/compact","contextWindowTokens":64000,"dailyResetHour":25,"flushModel":"test/extract","historyBudgetRatio":0.05,"idleMinutes":30,"timeZone":"Mars/Olympus"}"#
		let old = Data(
			(version == 1 ? #"{"sessionSettings":{"_0":\#(payload)}}"# : payload).utf8)
		let expected = try SessionSettings.npmDefaults
			.replacing(.historyBudgetRatio, with: "0.05")
			.replacing(.contextWindowOverride, with: "64000")
		let decoded = try RecordCodec.decode(
			kind: "sessionSettings", version: version, data: old, civilDate: "1998-06-13",
			ulid: "row-old"
		).get()
		#expect(decoded == .synced(.sessionSettings(SessionSettingsBody(settings: expected))))
		let store = InMemoryRecordLog()
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")
		try await seed(
			store,
			[seededRecord(store, at: clock.now, ulid: fixedUlid(1), body: decoded)])
		let coach = await makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		#expect(try await coach.observedStatus().session == expected)
		try await coach.setSession(expected.replacing(.historyBudgetRatio, with: "0.2"))
		await coach.lifecycle(.willTerminate)
		let reopened = await makeCoach(transport: FakeModelTransport(), store: store, clock: clock)
		let restored = try await reopened.observedStatus().session
		#expect(restored.historyBudgetRatio.value == 0.2)
		#expect(restored.contextWindowOverride?.tokens == 64_000)
		let records = try await store.fetch(RecordQuery(scope: .synced([.sessionSettings]))).records
		let encoded = try RecordCodec.encode(try #require(records.last).body).data
		let saved = try #require(
			try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		#expect(
			Set(saved.keys) == ["historyBudgetRatio", "contextWindowTokens"])
		await reopened.lifecycle(.willTerminate)
	}

	@Test func contextWindowOverrideIsCapped() throws {
		#expect(SessionSettings.npmDefaults.effectiveContextWindow == 200_000)
		let chosen = try SessionSettings.npmDefaults
			.replacing(.contextWindowOverride, with: "500000")
		#expect(chosen.effectiveContextWindow == 200_000)
		let small = try chosen.replacing(.contextWindowOverride, with: "32000")
		#expect(small.effectiveContextWindow == 32_000)
	}

	private func snapshot(of coach: Coach) async throws -> ChatSnapshot {
		try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) { _ in true
			})
	}
}
