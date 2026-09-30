import Foundation

struct SessionSettingsPayload: Codable {
	var historyBudgetRatio: Double
	var contextWindowTokens: Int?

	init(_ body: SessionSettingsBody) {
		let settings = body.settings
		self.historyBudgetRatio = settings.historyBudgetRatio.value
		self.contextWindowTokens = settings.contextWindowOverride?.tokens
	}

	func body() throws(SessionSettingRejected) -> SessionSettingsBody {
		SessionSettingsBody(
			settings: SessionSettings(
				historyBudgetRatio: try HistoryBudgetRatio(historyBudgetRatio),
				contextWindowOverride: try contextWindowTokens.map {
					(tokens: Int) throws(SessionSettingRejected) in
					try ContextWindowOverride(tokens: tokens)
				}
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
