import EnduragentCoach
import Foundation
import StoreKit

enum ShellRoute: Equatable {
	case loading
	case onboarding(OnboardingStep)
	case chat
}

enum OnboardingStep: Equatable {
	case notice
	case connect
	case starter
	case consent
	case consentDeferred
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
	var leases: @Sendable () async -> [LeaseRecord]
	var packPrices: @Sendable ([String]) async throws -> [String: String]

	#if DEBUG
		var fixture: FixtureServices?
	#endif

	@MainActor
	static func live(displayLocale: @escaping DisplayLocaleResolver) throws -> AppServices {
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
				clock: clock,
				openRouterSignIn: OpenRouterSignInService(authorizer: OpenRouterSignInSession())
			),
			builtInModel: builtInModel,
			displayLocale: displayLocale
		)
		return AppServices(
			coach: coach,
			deviceCheck: DeviceCheckTokenProvider(),
			clock: clock,
			leases: { await host.leases },
			packPrices: { identifiers in
				let products = try await Product.products(for: identifiers)
				return Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0.displayPrice) })
			}
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
	let defaults: UserDefaults
	let services: AppServices

	var deviceCheck: any DeviceCheckTokenProviding {
		services.deviceCheck
	}

	init(services: AppServices, defaults: UserDefaults) {
		self.defaults = defaults
		self.services = services
	}
}
