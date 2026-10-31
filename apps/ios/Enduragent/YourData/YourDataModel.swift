import EnduragentCoach
import Observation

@MainActor
@Observable
final class YourDataModel {
	enum Phase: Equatable {
		case idle
		case busy
		case deleting(ErasureRun)
		case finished(ErasureOutcome)
	}

	private(set) var phase: Phase
	private(set) var relaunchRequested = false
	private let coach: Coach
	private let device: DeviceDefaults

	init(coach: Coach, device: DeviceDefaults) {
		self.coach = coach
		self.device = device
		phase = device.erasureRun.map(Phase.deleting) ?? .idle
	}

	var isErasing: Bool {
		switch phase {
		case .idle, .busy: false
		case .deleting, .finished: true
		}
	}

	var isDeleting: Bool {
		guard case .deleting = phase else { return false }
		return true
	}

	var line: CatalogKey? {
		switch phase {
		case .idle: nil
		case .busy: Catalog.yourDataBusy
		case .deleting: Catalog.yourDataProgress
		case .finished(.done(.erased)): Catalog.yourDataDone
		case .finished(.done(.kept)): Catalog.yourDataCreditsKeptDone
		case .finished(.iCloudLater(.erased)): Catalog.yourDataICloudLater
		case .finished(.iCloudLater(.kept)): Catalog.yourDataCreditsKeptICloudLater
		case .finished(.notStarted): Catalog.yourDataNotStarted
		case .finished(.tryLater): Catalog.yourDataTryLater
		case .finished(.creditsUnconfirmed): Catalog.yourDataCreditsUnconfirmed
		case .finished(.notFinished): Catalog.yourDataNotFinished
		}
	}

	func begin() async {
		await begin(.everything)
	}

	func run() async {
		guard case .deleting(let run) = phase else { return }
		phase = .finished(await coach.continueErasure(run))
	}

	func tryAgain() async {
		switch phase {
		case .finished(.notStarted), .finished(.tryLater), .busy:
			await begin(.everything)
		case .finished(.notFinished(_, let resume)):
			phase = .deleting(resume)
		case .idle, .deleting, .finished(.done), .finished(.iCloudLater),
			.finished(.creditsUnconfirmed):
			return
		}
		await run()
	}

	func deleteKeepingCreditsRecord() async {
		guard phase == .finished(.creditsUnconfirmed) else { return }
		await begin(.thisPhoneAndICloud)
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
		case .busy, .finished(.notStarted), .finished(.tryLater), .finished(.creditsUnconfirmed):
			phase = .idle
		case .idle, .deleting, .finished: return
		}
	}

	private func begin(_ scope: ErasureScope) async {
		switch await coach.beginErasure(device, scope) {
		case .busy: phase = .busy
		case .begun(let run): phase = .deleting(run)
		}
	}
}
