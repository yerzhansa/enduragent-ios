import EnduragentCoach
import Foundation
import Observation

@MainActor
@Observable
final class ShellModel {
	var route: ShellRoute = .onboarding(.notice)
	var seam: ViewSeam = .empty
	var composer = ""
	var slashListVisible = false
	var athlete: AthleteProfile?
	var todayWellness: WellnessDay?
	var starterCredits: Credits?
	var starterLine: String?
	var balance: Credits?
	var catalog: PackCatalog?
	var history: [ChatSummary] = []
	var errorLine: String?
	var connectKey = ""
	var connectError: String?
	var didConnect = false
	var confirmLine: String?

	let builder: ServicesBuilder
	private var starterLoaded = false

	init(builder: ServicesBuilder) {
		self.builder = builder
	}

	var services: AppServices? {
		builder.services
	}

	var athleteFirstName: String {
		guard let name = athlete?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
			return ""
		}
		return name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
	}

	func continueNotice() {
		route = .onboarding(.connect)
	}

	func connect() async {
		do {
			let result = try await builder.connectIntervals(apiKey: connectKey)
			athlete = result.athlete
			todayWellness = result.wellness
			connectError = nil
			didConnect = true
		} catch {
			connectError = "intervals.icu did not accept that key"
			didConnect = false
		}
	}

	func continueConnect() {
		guard didConnect else { return }
		route = .onboarding(.starter)
	}

	func loadStarter() async {
		guard !starterLoaded else { return }
		starterLoaded = true
		do {
			let token = try await builder.deviceCheck.token()
			let outcome = try await builder.credits.grant(deviceCheck: token)
			switch outcome {
			case .minted(let credits):
				starterCredits = credits
				starterLine = "\(credits.units) credits"
			case .toppedUp(let added):
				starterLine = "Added \(added.units) credits"
			case .alreadyGranted:
				starterLine = "This device already used its starter credits."
			}
		} catch {
			starterLine = grantFailureName(error)
		}
	}

	func startChatting() {
		do {
			_ = try builder.completedServices()
			route = .chat
		} catch {
			errorLine = String(describing: error)
		}
	}

	private func grantFailureName(_ error: Error) -> String {
		if let failure = error as? CreditsFailure {
			return String(describing: failure)
		}
		return String(describing: error)
	}
}

struct ChatSummary: Identifiable, Equatable {
	var id: ChatID
	var title: String
	var civilDate: CivilDate
}
