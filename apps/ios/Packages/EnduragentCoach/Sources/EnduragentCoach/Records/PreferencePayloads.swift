import Foundation

struct SessionSettingsPayload: Codable {
	var historyBudgetRatio: Double
	var idleMinutes: Int
	var dailyResetHour: Int
	var archiveRetentionDays: Int
	var timeZone: String
	var contextWindowTokens: Int?
	var compactionModel: String
	var flushModel: String

	init(_ body: SessionSettingsBody) {
		let settings = body.settings
		self.historyBudgetRatio = settings.historyBudgetRatio.value
		self.idleMinutes = settings.idleReset.minutes
		self.dailyResetHour = settings.dailyResetHour.hour
		self.archiveRetentionDays = settings.archiveRetention.days
		self.timeZone = settings.timeZone.text
		self.contextWindowTokens = settings.contextWindowOverride?.tokens
		self.compactionModel = settings.compactionModel.text
		self.flushModel = settings.flushModel.text
	}

	func body() throws(SessionSettingRejected) -> SessionSettingsBody {
		SessionSettingsBody(
			settings: SessionSettings(
				historyBudgetRatio: try HistoryBudgetRatio(historyBudgetRatio),
				idleReset: try IdleReset(minutes: idleMinutes),
				dailyResetHour: try DailyResetHour(dailyResetHour),
				archiveRetention: try ArchiveRetention(days: archiveRetentionDays),
				timeZone: try SessionTimeZone(text: timeZone),
				contextWindowOverride: try contextWindowTokens.map {
					(tokens: Int) throws(SessionSettingRejected) in
					try ContextWindowOverride(tokens: tokens)
				},
				compactionModel: try ModelSelection(text: compactionModel, field: .compactionModel),
				flushModel: try ModelSelection(text: flushModel, field: .flushModel)
			))
	}
}

struct LanguagePreferencePayload: Codable {
	var tag: String?

	init(_ body: LanguagePreferenceBody) {
		switch body.preference {
		case .automatic: tag = nil
		case .fixed(let fixed): tag = fixed.rawValue
		}
	}

	func body() throws -> LanguagePreferenceBody {
		guard let tag else { return LanguagePreferenceBody(preference: .automatic) }
		guard let fixed = LanguageTag(rawValue: tag) else {
			throw RecordDecodeFailure(reason: "languagePreference")
		}
		return LanguagePreferenceBody(preference: .fixed(fixed))
	}
}
