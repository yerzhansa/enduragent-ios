import EnduragentCoach
import Foundation
import Observation

@MainActor
@Observable
final class OnboardingModel {
	var connectKey = ""
	private(set) var connectError: String?
	private(set) var didConnect = false
	private(set) var starterNotice: AthleteNotice?
	private(set) var starterResolved = false
	private(set) var consentNotSaved = false
	private(set) var isRecordingConsent = false
	private var starterLoaded = false
	private let environment: AppEnvironment

	static let completedKey = "enduragent.onboardingCompleted"

	init(environment: AppEnvironment) {
		self.environment = environment
	}

	var isCompleted: Bool {
		environment.defaults.bool(forKey: Self.completedKey)
	}

	func complete() {
		environment.defaults.set(true, forKey: Self.completedKey)
	}

	func connect(phrasebook: () -> CatalogPhrasebook) async {
		let outcome = await environment.services.coach.changeTraining(
			.replace(apiKey: connectKey, athlete: .keyOwner))
		switch outcome {
		case .replaced:
			connectKey = ""
			connectError = nil
			didConnect = true
		case .kept, .disconnected, .refused, .failedPreviousKept:
			connectError = phrasebook().say(Catalog.connectErrorRejected, [:])
			didConnect = false
		}
	}

	func continueConnect() -> Bool {
		guard didConnect else { return false }
		connectKey = ""
		return true
	}

	func skipConnect() {
		connectKey = ""
		didConnect = false
		connectError = nil
	}

	func loadStarter() async {
		guard !starterLoaded else { return }
		starterLoaded = true
		do {
			let token = try await environment.deviceCheck.token()
			let notice = await environment.services.coach.claimStarter(deviceCheck: token)
			starterNotice = notice
		} catch {
			starterNotice = AthleteNotice.credits(failure: error)
		}
		starterResolved = true
	}

	func acceptConsent(startChatting: () async -> Void) async {
		guard !isRecordingConsent else { return }
		isRecordingConsent = true
		defer { isRecordingConsent = false }
		consentNotSaved = false
		do {
			try await environment.services.coach.recordConsent()
		} catch {
			switch error {
			case .notSaved:
				consentNotSaved = true
			}
			return
		}
		await startChatting()
	}

	func declineConsent() {
		consentNotSaved = false
	}
}
