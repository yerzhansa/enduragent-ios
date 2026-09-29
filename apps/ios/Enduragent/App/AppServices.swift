import EnduragentCoach
import Foundation

enum ShellRoute: Equatable {
	case onboarding(OnboardingStep)
	case chat
}

enum OnboardingStep: Equatable {
	case notice
	case connect
	case starter
}

enum CivilDates {
	static func today(clock: any Clock) -> CivilDate {
		CivilDate(date: clock.now, timeZone: clock.timeZone)
	}
}

struct AppServices: Sendable {
	static var creditsWorkerBase: URL {
		let raw = Bundle.main.object(forInfoDictionaryKey: "CreditsWorkerBase") as? String
		guard let raw, let url = URL(string: raw) else {
			preconditionFailure("CreditsWorkerBase is missing from Info.plist")
		}
		return url
	}
	static var builtInModel: ModelID {
		let raw = Bundle.main.object(forInfoDictionaryKey: "OpenRouterModel") as? String
		guard let raw, !raw.isEmpty else {
			preconditionFailure("OpenRouterModel is missing from Info.plist")
		}
		return ModelID(rawValue: raw)
	}
	static var bundleIdentifier: String {
		guard let identifier = Bundle.main.bundleIdentifier else {
			preconditionFailure("The app bundle has no identifier")
		}
		return identifier
	}
	static let deviceDefaultsKey = "enduragent.deviceId"

	var coach: Coach
	var deviceCheck: any DeviceCheckTokenProviding
	var clock: any Clock
	var fixtureDirector: FixtureDirector?
	var leases: @Sendable () async -> [LeaseRecord]

	var isFixture: Bool {
		fixtureDirector != nil
	}

	var fixtureTransport: FakeModelTransport? {
		fixtureDirector?.transport
	}

	var fixtureRecordLog: FaultInjectingRecordLog? {
		fixtureDirector?.records
	}

	static func fixture(_ launch: FixtureLaunch, defaults: UserDefaults) throws -> AppServices {
		guard launch.name == FixtureLaunch.firstWeekName else {
			throw FixtureLaunchError.unknownFixture(launch.name)
		}
		FixtureBlockingURLProtocol.register()
		let clock = FixtureClock(
			calendar: FixedClock(now: launch.clock, timeZone: FixtureLaunch.timeZone))
		let intervals = FakeIntervalsClient(athleteName: FirstWeekFixture.athleteName, ftp: 250)
		FirstWeekFixture.install(on: intervals)
		let transport = FakeModelTransport()
		let fixture = try RecordStore.fixture(
			directory: launch.directory, deviceId: persistedDeviceID(in: defaults),
			unreadable: launch.store == .unreadable)
		let records = fixture.faults
		records.failRecoveryReads = launch.recovery == .unreadable
		let secrets = try FakeSecretStore(directory: launch.directory)
		if launch.keychain != .empty {
			try FirstWeekFixture.install(on: secrets)
		}
		secrets.locked = launch.keychain == .locked
		let credits = FakeCreditsClient()
		FirstWeekFixture.install(on: credits)
		let host = ImmediateExecutionHost(expiringAfter: launch.host.expiry)
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: fixture.store,
				secrets: secrets,
				models: .scripted(transport),
				training: FirstWeekFixture.training(intervals),
				credits: .fake(credits),
				host: host,
				clock: clock
			),
			builtInModel: builtInModel,
			deviceLanguage: Language.uiTag(systemLanguages: Locale.preferredLanguages),
			coalescing: launch.coalescing
		)
		return AppServices(
			coach: coach,
			deviceCheck: FakeDeviceCheckTokenProvider(),
			clock: clock,
			fixtureDirector: FixtureDirector(
				transport: transport, records: records, host: host, secrets: secrets,
				intervals: intervals, credits: credits),
			leases: { host.leases }
		)
	}

	@MainActor
	static func live(language: LanguageTag) throws -> AppServices {
		let clock = SystemClock()
		let store = try RecordStore.onDevice(deviceId: persistedDeviceID(in: .standard))
		let host = ContinuedProcessingHost(
			bundleIdentifier: bundleIdentifier, system: LiveBackgroundSystem())
		let coach = Coach(
			sport: .cycling,
			ports: CoachPorts(
				records: store,
				secrets: ICloudKeychainStore(),
				models: .openRouter(baseURL: ModelService.openRouterAPI),
				training: .intervalsREST,
				credits: .worker(creditsWorkerBase),
				host: host,
				clock: clock
			),
			builtInModel: builtInModel,
			deviceLanguage: language
		)
		return AppServices(
			coach: coach,
			deviceCheck: DeviceCheckTokenProvider(),
			clock: clock,
			fixtureDirector: nil,
			leases: { await host.leases }
		)
	}

	static func persistedDeviceID(in defaults: UserDefaults) -> DeviceID {
		if let stored = defaults.string(forKey: deviceDefaultsKey) {
			return DeviceID(rawValue: stored)
		}
		let created = DeviceID()
		defaults.set(created.rawValue, forKey: deviceDefaultsKey)
		return created
	}
}

@MainActor
final class AppEnvironment {
	let language: LanguageTag
	let defaults: UserDefaults
	let services: AppServices

	var deviceCheck: any DeviceCheckTokenProviding {
		services.deviceCheck
	}

	var isFixture: Bool {
		services.isFixture
	}

	static var isHostedByTests: Bool {
		ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
			|| ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
			|| NSClassFromString("XCTestCase") != nil
	}

	init(services: AppServices, language: LanguageTag, defaults: UserDefaults) {
		self.language = language
		self.defaults = defaults
		self.services = services
	}
}
