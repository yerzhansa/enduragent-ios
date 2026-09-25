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

enum ConnectFailure: Error {
	case emptyKey
	case rejected
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
	static let deviceDefaultsKey = "enduragent.deviceId"

	var coach: Coach
	var intervals: any IntervalsClient
	var credits: any CreditsClient
	var secrets: any SecretStore
	var deviceCheck: any DeviceCheckTokenProviding
	var phrasebook: any Phrasebook
	var clock: any Clock
	var isFixture: Bool
	var fixtureDirector: FixtureDirector?

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
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		let phrasebook = CatalogPhrasebook(tag: language, locale: language.defaultLocale)
		let clock = FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana")
		let intervals = FakeIntervalsClient(athleteName: FirstWeekFixture.athleteName, ftp: 250)
		FirstWeekFixture.install(on: intervals)
		let transport = FakeModelTransport()
		let records = FaultInjectingRecordLog(
			wrapping: SwiftDataRecordLog(
				deviceId: persistedDeviceID(in: defaults),
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: launch.directory.appending(
						path: ModelContainerHandle.syncedStoreFileName)),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: launch.directory.appending(
						path: ModelContainerHandle.localStoreFileName))
			)
		)
		let secrets = try FakeSecretStore(directory: launch.directory)
		secrets.locked = launch.keychain == .locked
		let credits = FakeCreditsClient()
		FirstWeekFixture.install(on: credits)
		let coach = Coach(
			sport: .cycling,
			transport: transport,
			intervals: intervals,
			store: records,
			clock: clock,
			language: LanguagePreference(ui: language, coachReply: nil)
		)
		return AppServices(
			coach: coach,
			intervals: intervals,
			credits: credits,
			secrets: secrets,
			deviceCheck: FakeDeviceCheckTokenProvider(),
			phrasebook: phrasebook,
			clock: clock,
			isFixture: true,
			fixtureDirector: FixtureDirector(transport: transport, records: records)
		)
	}

	static func live(language: LanguageTag) throws -> AppServices {
		let secrets = ICloudKeychainStore()
		let clock = SystemClock()
		let intervals: any IntervalsClient =
			if let credential = try secrets.intervalsCredential() {
				IntervalsRESTClient(credential: credential, clock: clock)
			} else {
				UnconnectedIntervalsClient()
			}
		let key = try secrets.openRouterKey() ?? ""
		let transport = OpenRouterTransport(apiKey: key)
		let directory = try ModelContainerHandle.applicationSupportDirectory()
		let store = SwiftDataRecordLog(
			deviceId: persistedDeviceID(in: .standard),
			synced: try ModelContainerHandle.syncedCloudKit(directory: directory),
			local: try ModelContainerHandle.deviceLocal(directory: directory)
		)
		let credits = PhoneCreditsClient(secrets: secrets, workerBase: creditsWorkerBase)
		let phrasebook = CatalogPhrasebook(tag: language, locale: language.defaultLocale)
		let coach = Coach(
			sport: .cycling,
			transport: transport,
			intervals: intervals,
			store: store,
			clock: clock,
			language: LanguagePreference(ui: language, coachReply: nil)
		)
		return AppServices(
			coach: coach,
			intervals: intervals,
			credits: credits,
			secrets: secrets,
			deviceCheck: DeviceCheckTokenProvider(),
			phrasebook: phrasebook,
			clock: clock,
			isFixture: false,
			fixtureDirector: nil
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
final class ServicesBuilder {
	let language: LanguageTag
	let phrasebook: any Phrasebook
	let secrets: any SecretStore
	let credits: any CreditsClient
	let deviceCheck: any DeviceCheckTokenProviding
	let clock: any Clock
	let isFixture: Bool
	let defaults: UserDefaults
	private(set) var intervals: any IntervalsClient
	private(set) var services: AppServices?
	var completedServicesFailure: (any Error)?

	static func bootstrap() -> ServicesBuilder {
		let language = Language.uiTag(systemLanguages: Locale.preferredLanguages)
		do {
			guard let launch = try fixtureLaunch() else {
				return ServicesBuilder(liveLanguage: language)
			}
			let defaults = try launch.prepare()
			let services = try AppServices.fixture(launch, defaults: defaults)
			return ServicesBuilder(fixture: services, language: language, defaults: defaults)
		} catch {
			fatalError("The fixture launch failed: \(error)")
		}
	}

	private static func fixtureLaunch() throws -> FixtureLaunch? {
		if let launch = try FixtureLaunch.fromArguments() {
			return launch
		}
		return isHostedByTests ? try FixtureLaunch.firstWeek() : nil
	}

	static var isHostedByTests: Bool {
		ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
			|| ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
			|| NSClassFromString("XCTestCase") != nil
	}

	init(fixture services: AppServices, language: LanguageTag, defaults: UserDefaults) {
		self.language = language
		self.phrasebook = services.phrasebook
		self.secrets = services.secrets
		self.credits = services.credits
		self.deviceCheck = services.deviceCheck
		self.clock = services.clock
		self.isFixture = true
		self.defaults = defaults
		self.intervals = services.intervals
		self.services = services
	}

	private init(liveLanguage language: LanguageTag) {
		self.language = language
		self.phrasebook = CatalogPhrasebook(tag: language, locale: language.defaultLocale)
		let secrets = ICloudKeychainStore()
		self.secrets = secrets
		self.credits = PhoneCreditsClient(
			secrets: secrets, workerBase: AppServices.creditsWorkerBase)
		self.deviceCheck = DeviceCheckTokenProvider()
		self.clock = SystemClock()
		self.isFixture = false
		self.defaults = .standard
		self.intervals = UnconnectedIntervalsClient()
		self.services = nil
	}

	func connectIntervals(apiKey: String) async throws -> (
		athlete: AthleteProfile, wellness: WellnessDay?
	) {
		if apiKey.isEmpty {
			throw ConnectFailure.emptyKey
		}
		if isFixture {
			try secrets.storeIntervalsCredential(.apiKey(apiKey))
			return try await fetchConnectedProfile()
		}
		let client = IntervalsRESTClient(credential: .apiKey(apiKey), clock: clock)
		do {
			let athlete = try await client.fetchAthlete()
			let today = CivilDates.today(clock: clock)
			let days = try await client.fetchWellness(oldest: today, newest: today)
			try secrets.storeIntervalsCredential(.apiKey(apiKey))
			intervals = client
			return (athlete, days.first)
		} catch {
			throw ConnectFailure.rejected
		}
	}

	func completedServices() throws -> AppServices {
		if let completedServicesFailure {
			throw completedServicesFailure
		}
		if let services {
			return services
		}
		let built = try AppServices.live(language: language)
		services = built
		intervals = built.intervals
		return built
	}

	private func fetchConnectedProfile() async throws -> (
		athlete: AthleteProfile, wellness: WellnessDay?
	) {
		do {
			let athlete = try await intervals.fetchAthlete()
			let today = CivilDates.today(clock: clock)
			let days = try await intervals.fetchWellness(oldest: today, newest: today)
			return (athlete, days.first)
		} catch {
			throw ConnectFailure.rejected
		}
	}
}
