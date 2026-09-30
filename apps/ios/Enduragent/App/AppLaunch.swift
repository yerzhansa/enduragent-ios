import EnduragentCoach
import Foundation

@MainActor
enum AppLaunch {
	case ready(ShellModel)
	case storageUnavailable(CatalogPhrasebook, failure: any Error)

	static func start() async -> AppLaunch {
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		return await open(language: language) {
			guard let fixture = try fixtureLaunch() else {
				return (try AppServices.live(language: language), .standard)
			}
			let defaults = try fixture.prepare()
			return (try AppServices.fixture(fixture, defaults: defaults), defaults)
		}
	}

	static func open(
		language: LanguageTag, _ services: () throws -> (AppServices, UserDefaults)
	) async -> AppLaunch {
		do {
			let (built, defaults) = try services()
			let preference = await built.coach.languagePreference()
			let model = ShellModel(
				environment: AppEnvironment(
					services: built, language: language, defaults: defaults),
				initialLanguage: preference)
			return .ready(model)
		} catch let error as FixtureLaunchError {
			fatalError("The fixture launch arguments are invalid: \(error)")
		} catch {
			return .storageUnavailable(
				CatalogPhrasebook(tag: language), failure: error)
		}
	}

	private static func fixtureLaunch() throws -> FixtureLaunch? {
		if let launch = try FixtureLaunch.fromArguments() {
			return launch
		}
		return AppEnvironment.isHostedByTests ? try FixtureLaunch.firstWeek() : nil
	}
}
