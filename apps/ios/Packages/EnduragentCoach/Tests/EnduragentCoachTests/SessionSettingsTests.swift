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
		(.contextWindowOverride, "0", "Enter a safe whole number of tokens, 1 or more."),

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
		settings = try settings.replacing(.contextWindowOverride, with: "64000")
		#expect(settings.historyBudgetRatio.value == 0.05)
		#expect(settings.contextWindowOverride?.tokens == 64_000)
		let cleared = try settings.replacing(.contextWindowOverride, with: " ")
		#expect(cleared.contextWindowOverride == nil)
	}

	@Test func setSessionStoresOneRecordThatTheNextCoachReads() async throws {
		let store = InMemoryRecordLog()
		let coach = await makeCoach(transport: FakeModelTransport(), store: store)
		#expect(try await coach.observedStatus().session == .npmDefaults)
		let chosen = try SessionSettings.npmDefaults.replacing(.historyBudgetRatio, with: "0.05")
			.replacing(.contextWindowOverride, with: "64000")
		try await coach.setSession(chosen)
		#expect(try await coach.observedStatus().session == chosen)
		#expect(
			try await makeCoach(transport: FakeModelTransport(), store: store).observedStatus()
				.session
				== chosen)
		#expect(
			try await store.fetch(RecordQuery(scope: .synced([.sessionSettings]))).records.count
				== 1)
	}

	@Test func failedSessionWriteKeepsTheStoredSettings() async throws {
		let log = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let coach = await makeCoach(transport: FakeModelTransport(), store: log)
		try log.failAppends(ofKind: "sessionSettings")
		let chosen = try SessionSettings.npmDefaults.replacing(.historyBudgetRatio, with: "0.5")
		await #expect(throws: PreferenceWriteFailure.notSaved) {
			try await coach.setSession(chosen)
		}
		#expect(try await coach.observedStatus().session == .npmDefaults)
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

	@Test func aStoredRowWithRetiredResetKeysKeepsItsOtherSettings() throws {
		let old = Data(
			#"{"archiveRetentionDays":14,"compactionModel":"test/compact","contextWindowTokens":64000,"dailyResetHour":25,"flushModel":"","historyBudgetRatio":0.05,"idleMinutes":30,"timeZone":"Mars/Olympus"}"#
				.utf8)
		let expected = try SessionSettings.npmDefaults
			.replacing(.historyBudgetRatio, with: "0.05")
			.replacing(.contextWindowOverride, with: "64000")
		#expect(
			RecordCodec.decode(
				kind: "sessionSettings", version: 2, data: old, civilDate: "1998-06-13",
				ulid: "row-old")
				== .success(.synced(.sessionSettings(SessionSettingsBody(settings: expected)))))
	}

	@Test func contextWindowOverrideIsCapped() throws {
		#expect(SessionSettings.npmDefaults.effectiveContextWindow == 200_000)
		let chosen = try SessionSettings.npmDefaults
			.replacing(.contextWindowOverride, with: "500000")
		#expect(chosen.effectiveContextWindow == 200_000)
		let small = try chosen.replacing(.contextWindowOverride, with: "32000")
		#expect(small.effectiveContextWindow == 32_000)
	}
}
