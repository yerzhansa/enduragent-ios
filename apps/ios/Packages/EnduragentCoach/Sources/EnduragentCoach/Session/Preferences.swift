import Foundation

public enum LanguagePreference: Sendable, Hashable, Identifiable {
	case automatic
	case fixed(LanguageTag)

	public static let choices: [LanguagePreference] =
		[.automatic] + LanguageTag.contractOrder.map(LanguagePreference.fixed)

	public var id: String {
		switch self {
		case .automatic: "automatic"
		case .fixed(let tag): tag.rawValue
		}
	}

	public func title(in phrasebook: any Phrasebook) -> String {
		switch self {
		case .automatic: phrasebook.say(Catalog.commonAutomatic, [:])
		case .fixed(let tag): tag.endonym
		}
	}

	public func notSaved(keeping current: LanguagePreference, in phrasebook: any Phrasebook)
		-> String
	{
		switch current {
		case .automatic:
			phrasebook.say(Catalog.languageSaveFailedAutomatic, ["language": title(in: phrasebook)])
		case .fixed(let tag):
			phrasebook.say(
				Catalog.languageSaveFailed,
				["language": title(in: phrasebook), "current": tag.endonym])
		}
	}

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
