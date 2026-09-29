import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct SessionSettingsTests {
	private let english = CatalogPhrasebook(tag: .en, locale: "en-GB")

	@Test func defaultsMatchNpm() {
		let defaults = SessionSettings.npmDefaults
		#expect(defaults.historyBudgetRatio.value == 0.3)
		#expect(defaults.idleReset == .off)
		#expect(defaults.dailyResetHour.hour == 4)
		#expect(defaults.archiveRetention == .forever)
		#expect(defaults.timeZone == .device)
		#expect(defaults.contextWindowOverride == nil)
		#expect(defaults.compactionModel == .sameAsResponse)
		#expect(defaults.flushModel == .sameAsResponse)
		#expect(
			SessionField.allCases.map { defaults.text(for: $0) } == [
				"0.3", "0", "4", "0", "", "", "", "",
			])
	}

	@Test(arguments: [
		(
			SessionField.historyBudgetRatio, "0",
			"Enter a history budget above 0% and no more than 100%."
		),
		(.historyBudgetRatio, "1.5", "Enter a history budget above 0% and no more than 100%."),
		(.idleReset, "-1", "Enter a safe whole number of minutes, 0 or more."),
		(.idleReset, "2.5", "Enter a safe whole number of minutes, 0 or more."),
		(.dailyResetHour, "24", "Enter a whole hour from 0 to 23."),
		(.dailyResetHour, "25", "Enter a whole hour from 0 to 23."),
		(.archiveRetention, "-3", "Enter a safe whole number of days, 0 or more."),
		(.timeZone, "Mars/Olympus", "Enter a valid IANA timezone, such as Europe/London."),
		(.contextWindowOverride, "0", "Enter a safe whole number of tokens, 1 or more."),
		(.compactionModel, "open\u{7}router", "Model names can’t contain control characters."),
		(
			.flushModel, String(repeating: "m", count: 513),
			"Model names must be 512 characters or fewer."
		),
	])
	func eachFieldRejectsItsInvalidValue(field: SessionField, text: String, sentence: String) {
		let stored = SessionSettings.npmDefaults
		do {
			_ = try stored.replacing(field, with: text)
			Issue.record("\(field) accepted \(text)")
		} catch {
			#expect(error.field == field)
			#expect(error.sentence(in: english) == sentence)
		}
		#expect(stored == .npmDefaults)
	}

	@Test func validValuesReplaceOnlyTheirField() throws {
		var settings = SessionSettings.npmDefaults
		settings = try settings.replacing(.historyBudgetRatio, with: "0.05")
		settings = try settings.replacing(.idleReset, with: "30")
		settings = try settings.replacing(.dailyResetHour, with: "0")
		settings = try settings.replacing(.archiveRetention, with: "14")
		settings = try settings.replacing(.timeZone, with: " Asia/Tokyo ")
		settings = try settings.replacing(.contextWindowOverride, with: "64000")
		settings = try settings.replacing(.compactionModel, with: "test/compact")
		settings = try settings.replacing(.flushModel, with: "test/flush")
		#expect(settings.historyBudgetRatio.value == 0.05)
		#expect(settings.idleReset == .after(minutes: 30))
		#expect(settings.dailyResetHour.hour == 0)
		#expect(settings.archiveRetention == .days(14))
		#expect(settings.timeZone == .fixed(try #require(IANATimeZone(identifier: "Asia/Tokyo"))))
		#expect(settings.contextWindowOverride?.tokens == 64_000)
		#expect(settings.compactionModel == .model(ModelID(rawValue: "test/compact")))
		#expect(settings.flushModel == .model(ModelID(rawValue: "test/flush")))
		let cleared = try settings.replacing(.timeZone, with: "")
			.replacing(.contextWindowOverride, with: " ")
			.replacing(.compactionModel, with: "")
			.replacing(.idleReset, with: "0")
		#expect(cleared.timeZone == .device)
		#expect(cleared.contextWindowOverride == nil)
		#expect(cleared.compactionModel == .sameAsResponse)
		#expect(cleared.idleReset == .off)
		#expect(cleared.flushModel == .model(ModelID(rawValue: "test/flush")))
	}

	@Test func setSessionStoresOneRecordThatTheNextCoachReads() async throws {
		let store = InMemoryRecordLog()
		let coach = makeCoach(transport: FakeModelTransport(), store: store)
		#expect(await coach.status().session == .npmDefaults)
		let chosen = try SessionSettings.npmDefaults.replacing(.dailyResetHour, with: "6")
			.replacing(.timeZone, with: "Asia/Tokyo")
		try await coach.setSession(chosen)
		#expect(await coach.status().session == chosen)
		#expect(
			await makeCoach(transport: FakeModelTransport(), store: store).status().session
				== chosen)
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.sessionSettings]))).records.count
				== 1)
	}

	@Test func failedSessionWriteKeepsTheStoredSettings() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let coach = makeCoach(transport: FakeModelTransport(), store: log)
		log.failAppends(ofKind: "sessionSettings")
		let chosen = try SessionSettings.npmDefaults.replacing(.idleReset, with: "30")
		await #expect(throws: PreferenceWriteFailure.notSaved) {
			try await coach.setSession(chosen)
		}
		#expect(await coach.status().session == .npmDefaults)
	}

	@Test func storedValuesOutsideTheirRangeDecodeAsMalformedRows() {
		let hour = Data(
			#"{"archiveRetentionDays":0,"compactionModel":"","dailyResetHour":25,"flushModel":"","historyBudgetRatio":0.3,"idleMinutes":0,"timeZone":""}"#
				.utf8)
		#expect(
			RecordCodec.decode(
				kind: "sessionSettings", version: 2, data: hour, civilDate: "1998-06-13",
				ulid: "row-hour")
				== .failure(.malformed(kind: "sessionSettings", ulid: "row-hour")))
		let tag = Data(#"{"tag":"xx"}"#.utf8)
		#expect(
			RecordCodec.decode(
				kind: "languagePreference", version: 2, data: tag, civilDate: "1998-06-13",
				ulid: "row-tag")
				== .failure(.malformed(kind: "languagePreference", ulid: "row-tag")))
	}

	@Test func modelRolesResolveSameAsResponseAndCapTheWindow() throws {
		let response = ModelID(rawValue: "test/chat")
		let defaults = ModelRoles(response: response, session: .npmDefaults)
		#expect(defaults.compaction == response)
		#expect(defaults.flush == response)
		#expect(defaults.chatWindow == 200_000)
		let chosen = try SessionSettings.npmDefaults
			.replacing(.compactionModel, with: "test/compact")
			.replacing(.contextWindowOverride, with: "500000")
		let roles = ModelRoles(response: response, session: chosen)
		#expect(roles.compaction == ModelID(rawValue: "test/compact"))
		#expect(roles.flush == response)
		#expect(roles.chatWindow == 200_000)
		let small = try chosen.replacing(.contextWindowOverride, with: "32000")
		#expect(ModelRoles(response: response, session: small).chatWindow == 32_000)
	}
}
