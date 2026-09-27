import Foundation

public enum LanguagePreference: Sendable, Equatable {
	case automatic
	case fixed(LanguageTag)

	public func appLanguage(device: LanguageTag) -> LanguageTag {
		switch self {
		case .automatic: device
		case .fixed(let tag): tag
		}
	}

	public func phrasebook(device: LanguageTag) -> CatalogPhrasebook {
		let tag = appLanguage(device: device)
		return CatalogPhrasebook(tag: tag, locale: tag.defaultLocale)
	}

	package func replyLanguage(for message: String, device: LanguageTag) -> LanguageResolution {
		switch self {
		case .automatic:
			Language.resolve(
				saved: nil, messageHint: Language.detectMessageLanguage(message), surface: device)
		case .fixed(let tag):
			Language.resolve(saved: tag, messageHint: nil, surface: device)
		}
	}
}

public enum PreferenceWriteFailure: Error, Sendable, Equatable {
	case notSaved
}

package struct Preferences: Sendable, Equatable {
	package static let scope: RecordQuery.Scope = .synced([
		.sessionSettings, .languagePreference, .coachReplyLanguage,
	])
	package static let npmDefaults = Preferences(language: .automatic, session: .npmDefaults)

	package var language: LanguagePreference
	package var session: SessionSettings

	package static func fold(_ records: [AthleteRecord]) -> Preferences {
		var folded = npmDefaults
		var chosen = false
		var legacy: LanguagePreference?
		for record in records.sorted(by: { $0.hlc < $1.hlc }) {
			switch record.body {
			case .synced(.sessionSettings(let body)):
				folded.session = body.settings
			case .synced(.languagePreference(let body)):
				folded.language = body.preference
				chosen = true
			case .synced(.coachReplyLanguage(let body)):
				legacy = body.tag.map(LanguagePreference.fixed) ?? .automatic
			default:
				continue
			}
		}
		if !chosen, let legacy {
			folded.language = legacy
		}
		return folded
	}
}
