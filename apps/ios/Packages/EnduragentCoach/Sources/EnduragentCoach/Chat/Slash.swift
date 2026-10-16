import Foundation

public enum SlashCommand: String, Sendable, CaseIterable {
	case start = "/start"
	case workout = "/workout"
	case status = "/status"
	case review = "/review"
	case language = "/language"

	public var menuTitle: CatalogKey {
		switch self {
		case .start: Catalog.telegramMenuStart
		case .workout: Catalog.telegramMenuWorkout
		case .status: Catalog.telegramMenuStatus
		case .review: Catalog.telegramMenuReview
		case .language: Catalog.telegramLanguageChoose
		}
	}

	package var route: SlashRoute {
		switch self {
		case .start: .resetConversation
		case .language: .languagePicker
		case .workout, .status, .review: .modelTurn
		}
	}
}

package enum SlashRoute: Sendable, Equatable {
	case resetConversation
	case languagePicker
	case modelTurn
}

public enum SlashRouting {
	public static func parse(_ text: String) -> SlashCommand? {
		guard let token = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first
		else {
			return nil
		}
		return SlashCommand(rawValue: String(token))
	}
}
