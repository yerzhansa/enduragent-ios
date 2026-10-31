import Foundation

public enum SlashCommand: String, Sendable, CaseIterable {
	case start = "/start"
	case workout = "/workout"
	case plan = "/plan"
	case status = "/status"
	case review = "/review"
	case language = "/language"
	case feedback = "/feedback"
	case version = "/version"

	public var menuTitle: CatalogKey {
		switch self {
		case .start: Catalog.telegramMenuStart
		case .workout: Catalog.telegramMenuWorkout
		case .plan: Catalog.telegramMenuPlan
		case .status: Catalog.telegramMenuStatus
		case .review: Catalog.telegramMenuReview
		case .language: Catalog.telegramLanguageChoose
		case .feedback: Catalog.feedbackCommand
		case .version: Catalog.chatCommandsVersion
		}
	}

	package var route: SlashRoute {
		switch self {
		case .start: .resetConversation
		case .language: .languagePicker
		case .workout, .plan, .status, .review: .modelTurn
		case .feedback: .screen(.feedback)
		case .version: .screen(.about)
		}
	}
}

package enum SlashRoute: Sendable, Equatable {
	case resetConversation
	case languagePicker
	case modelTurn
	case screen(SlashScreen)
}

public enum SlashScreen: Sendable, Equatable {
	case feedback
	case about
}

public enum SlashRouting {
	public static func parse(_ text: String) -> SlashCommand? {
		guard let token = tokens(of: text).first else { return nil }
		return SlashCommand(rawValue: String(token))
	}

	package static func argument(of text: String) -> String {
		guard let token = tokens(of: text).first else { return "" }
		return text[token.endIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func tokens(of text: String) -> [Substring] {
		text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
	}
}
