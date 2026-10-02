import EnduragentCoach
import Foundation

extension AppServices {
	static let resolveDisplayLocale: DisplayLocaleResolver = { preference in
		DisplayLocale(
			preference: preference, preferredLanguages: Locale.preferredLanguages,
			regionalConventions: Locale.current)
	}
}
