import EnduragentCoach
import Foundation

@MainActor
enum AppLaunch {
	case ready(ShellModel)
	case storageUnavailable(DisplayLocale, failure: any Error)

	static func start() async -> AppLaunch {
		await open(displayLocale: AppServices.resolveDisplayLocale) { displayLocale in
			#if DEBUG
				if let fixture = try fixtureLaunch() {
					let defaults = try fixture.prepare()
					return (
						try AppServices.fixture(
							fixture, defaults: defaults, displayLocale: displayLocale,
							backgroundSystem: LiveBackgroundSystem()),
						defaults
					)
				}
			#endif
			return (try AppServices.live(displayLocale: displayLocale), .standard)
		}
	}

	static func open(
		displayLocale: @escaping DisplayLocaleResolver,
		_ services: (@escaping DisplayLocaleResolver) throws -> (AppServices, UserDefaults)
	) async -> AppLaunch {
		do {
			let (built, defaults) = try services(displayLocale)
			let statuses = await built.coach.observeStatus()
			let model = await ShellModel.open(
				environment: AppEnvironment(services: built, defaults: defaults), statuses: statuses
			)
			return .ready(model)
		} catch {
			#if DEBUG
				if let error = error as? FixtureLaunchError {
					fatalError("The fixture launch arguments are invalid: \(error)")
				}
			#endif
			return .storageUnavailable(
				displayLocale(.automatic), failure: error)
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
