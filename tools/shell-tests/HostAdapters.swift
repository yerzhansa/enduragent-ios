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

enum HistoryList: Equatable {
	case loading
	case loaded([ArchivedConversation])
	case unavailable
}

protocol DeviceCheckTokenProviding: Sendable {
	func token() async throws -> Data
}

struct FakeDeviceCheckTokenProvider: DeviceCheckTokenProviding {
	func token() async throws -> Data {
		Data([1])
	}
}

struct FixtureDirector: Sendable {
	enum Outcome {
		case ready
		case rejected(String)
	}

	func prepare(for _: String) async -> Outcome {
		.ready
	}
}

struct AppServices: Sendable {
	var coach: Coach
	var deviceCheck: any DeviceCheckTokenProviding
	var clock: any Clock
	var fixtureDirector: FixtureDirector?
	var leases: @Sendable () async -> [LeaseRecord]

	var isFixture: Bool {
		fixtureDirector != nil
	}

	static func live(language _: LanguageTag) throws -> AppServices {
		throw HostServicesUnavailable()
	}

	static func fixture(_: FixtureLaunch, defaults _: UserDefaults) throws -> AppServices {
		throw HostServicesUnavailable()
	}
}

@MainActor
final class ServicesBuilder {
	let services: AppServices
	let language: LanguageTag
	let defaults: UserDefaults
	static let isHostedByTests = true

	var deviceCheck: any DeviceCheckTokenProviding {
		services.deviceCheck
	}

	init(services: AppServices, language: LanguageTag, defaults: UserDefaults) {
		self.services = services
		self.language = language
		self.defaults = defaults
	}
}

@MainActor
final class AppLifecycle {
	private let builder: ServicesBuilder

	init(builder: ServicesBuilder) {
		self.builder = builder
	}

	func forward(_ event: AppLifecycleEvent) async {
		await builder.services.coach.lifecycle(event)
	}
}

struct HostServicesUnavailable: Error {}

struct FixtureLaunchError: Error {}

struct FixtureLaunch {
	static func fromArguments() throws -> FixtureLaunch? {
		throw HostServicesUnavailable()
	}

	static func firstWeek() throws -> FixtureLaunch {
		throw HostServicesUnavailable()
	}

	func prepare() throws -> UserDefaults {
		throw HostServicesUnavailable()
	}
}
