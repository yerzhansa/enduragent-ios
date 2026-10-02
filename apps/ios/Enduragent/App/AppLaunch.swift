import EnduragentCoach
import Foundation

@MainActor
enum AppLaunch {
	case ready(ShellModel)
	case storageUnavailable(CatalogPhrasebook, failure: any Error)

	static func start() async -> AppLaunch {
		await open(systemLanguages: Locale.preferredLanguages) { language in
			#if DEBUG
				if let fixture = try fixtureLaunch() {
					let defaults = try fixture.prepare()
					return (
						try AppServices.fixture(
							fixture, defaults: defaults, language: language,
							backgroundSystem: LiveBackgroundSystem()),
						defaults
					)
				}
			#endif
			return (try AppServices.live(language: language), .standard)
		}
	}

	static func open(
		systemLanguages: [String], _ services: (LanguageTag) throws -> (AppServices, UserDefaults)
	) async -> AppLaunch {
		let language = Language.uiTag(systemLanguages: systemLanguages)
		do {
			let (built, defaults) = try services(language)
			let preference = await built.coach.languagePreference()
			let model = ShellModel(
				environment: AppEnvironment(
					services: built, language: language, defaults: defaults),
				initialLanguage: preference)
			return .ready(model)
		} catch {
			#if DEBUG
				if let error = error as? FixtureLaunchError {
					fatalError("The fixture launch arguments are invalid: \(error)")
				}
			#endif
			return .storageUnavailable(
				CatalogPhrasebook(tag: language), failure: error)
		}
	}

	#if DEBUG
		private static func fixtureLaunch() throws -> FixtureLaunch? {
			if let launch = try FixtureLaunch.fromArguments() {
				return launch
			}
			return isHostedByTests ? try FixtureLaunch.firstWeek() : nil
		}
		private static var isHostedByTests: Bool {
			ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
				|| ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
				|| NSClassFromString("XCTestCase") != nil
		}
	#endif
}
