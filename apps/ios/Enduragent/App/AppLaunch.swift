import EnduragentCoach
import Foundation

@MainActor
enum AppLaunch {
	case ready(ShellModel)
	case storageUnavailable(any Phrasebook, failure: any Error)

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
			let model = ShellModel(
				builder: ServicesBuilder(services: built, language: language, defaults: defaults))
			await model.refreshStatus()
			return .ready(model)
		} catch let error as FixtureLaunchError {
			fatalError("The fixture launch arguments are invalid: \(error)")
		} catch {
			return .storageUnavailable(
				CatalogPhrasebook(tag: language, locale: language.defaultLocale), failure: error)
		}
	}

	private static func fixtureLaunch() throws -> FixtureLaunch? {
		if let launch = try FixtureLaunch.fromArguments() {
			return launch
		}
		return ServicesBuilder.isHostedByTests ? try FixtureLaunch.firstWeek() : nil
	}
}
