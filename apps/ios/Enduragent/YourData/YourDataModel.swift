import EnduragentCoach
import Observation

@MainActor
@Observable
final class YourDataModel {
	enum Phase: Equatable {
		case idle
		case busy
		case deleting
		case finished(ErasureOutcome)
	}

	private(set) var phase: Phase
	private(set) var relaunchRequested = false
	private let coach: Coach
	private let device: DeviceDefaults

	init(coach: Coach, device: DeviceDefaults) {
		self.coach = coach
		self.device = device
		switch device.erasure {
		case .started?, .creditsErased?: phase = .deleting
		case .iCloudPending?, nil: phase = .idle
		}
	}

	var isErasing: Bool {
		switch phase {
		case .idle, .busy: false
		case .deleting, .finished: true
		}
	}

	var line: CatalogKey? {
		switch phase {
		case .idle: nil
		case .busy: Catalog.yourDataBusy
		case .deleting: Catalog.yourDataProgress
		case .finished(.done): Catalog.yourDataDone
		case .finished(.iCloudLater): Catalog.yourDataICloudLater
		case .finished(.notStarted): Catalog.yourDataNotStarted
		case .finished(.notFinished): Catalog.yourDataNotFinished
		}
	}

	func begin() async {
		switch await coach.beginErasure(device) {
		case .busy: phase = .busy
		case .begun: phase = .deleting
		}
	}

	func run() async {
		guard phase == .deleting else { return }
		phase = .finished(await coach.continueErasure(device))
	}

	func tryAgain() async {
		switch phase {
		case .finished(.notStarted), .busy:
			await begin()
		case .finished(.notFinished):
			phase = .deleting
		case .idle, .deleting, .finished(.done), .finished(.iCloudLater):
			return
		}
		await run()
	}

	func finish() {
		relaunchRequested = true
	}

	func forgetBusy() {
		if phase == .busy { phase = .idle }
	}

	func cancel() {
		switch phase {
		case .busy, .finished(.notStarted): phase = .idle
		case .idle, .deleting, .finished: return
		}
	}
}
