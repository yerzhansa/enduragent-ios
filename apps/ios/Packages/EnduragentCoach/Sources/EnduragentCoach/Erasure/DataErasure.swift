import Foundation

public enum ErasureScope: Sendable, Equatable {
	case everything
	case thisPhoneAndICloud
}

public enum ErasureStart: Sendable, Equatable {
	case begun(ErasureRun)
	case busy
}

public enum ErasureStep: String, Sendable, Equatable, CaseIterable {
	case iCloud
	case deviceRecords
	case files
	case keychain
}

public enum ErasureOutcome: Sendable, Equatable {
	case done(CreditsRecordFate)
	case iCloudLater(CreditsRecordFate)
	case notStarted
	case tryLater
	case creditsUnconfirmed
	case notFinished(ErasureStep, resume: ErasureRun)
}

extension Coach {
	public func beginErasure(_ device: DeviceDefaults, _ scope: ErasureScope) async -> ErasureStart
	{
		guard await isIdle() else { return .busy }
		pendingErasure?.cancel()
		await pendingErasure?.value
		pendingErasure = nil
		let progress: ErasureProgress =
			switch scope {
			case .everything: .askingCredits
			case .thisPhoneAndICloud:
				.erasingLocally(LocalErasure(credits: .kept, iCloud: .notErased))
			}
		let began = clock.now
		device.mark(.running(progress, began: began))
		return .begun(ErasureRun(progress: progress, began: began, device: device))
	}

	public func continueErasure(_ run: ErasureRun) async -> ErasureOutcome {
		let local: LocalErasure
		switch run.progress {
		case .askingCredits:
			do {
				try await credits.erase()
			} catch {
				run.device.mark(nil)
				diagnostics.record(.erasureNotStarted(FailureCode(error)))
				return ErasureOutcome(refusal: error)
			}
			local = LocalErasure(credits: .erased, iCloud: .notErased)
		case .erasingLocally(let resumed):
			local = resumed
		}
		await lifecycle(.willTerminate)
		return await eraseFromThisPhone(LocalRun(local, of: run))
	}

	public func eraseReturningRows(_ device: DeviceDefaults) {
		guard case .iCloudPending(let began)? = device.erasure else { return }
		let ledger = ledger
		let diagnostics = diagnostics
		let clock = clock
		pendingErasure = Task {
			do {
				let saved = clock.now
				_ = try await ledger.erase(.synced, writtenBefore: began)
				if try await ledger.confirmSyncedExport(after: saved) { device.mark(nil) }
			} catch is CancellationError {
				return
			} catch {
				diagnostics.record(.erasureUnconfirmed(FailureCode(error)))
			}
		}
	}

	private func eraseFromThisPhone(_ start: LocalRun) async -> ErasureOutcome {
		var run = start
		if run.local.iCloud != .confirmed {
			do {
				let resumed = run.local.iCloud == .erasedUnconfirmed
				let erased = try await ledger.erase(.synced, writtenBefore: nil)
				run.advance(iCloud: .erasedUnconfirmed)
				if erased > 0 || resumed, try await ledger.confirmSyncedExport(after: clock.now) {
					run.advance(iCloud: .confirmed)
				}
			} catch {
				return stopped(at: .iCloud, error, run)
			}
		}
		do {
			_ = try await ledger.erase(.deviceLocal, writtenBefore: nil)
		} catch {
			return stopped(at: .deviceRecords, error, run)
		}
		do {
			try await support.eraseFiles()
			try await catalogs.eraseCache()
		} catch {
			return stopped(at: .files, error, run)
		}
		do {
			try await vault.eraseSecrets()
		} catch {
			return stopped(at: .keychain, error, run)
		}
		let exported = run.local.iCloud == .confirmed
		run.device.erase(keeping: exported ? nil : .iCloudPending(began: run.began))
		return exported ? .done(run.local.credits) : .iCloudLater(run.local.credits)
	}

	private func stopped(at step: ErasureStep, _ error: any Error, _ run: LocalRun)
		-> ErasureOutcome
	{
		diagnostics.record(.erasureNotFinished(step, FailureCode(error)))
		return .notFinished(step, resume: run.resumable)
	}

	private func isIdle() async -> Bool {
		guard host.isIdle else { return false }
		for mailbox in mailboxes.values where await mailbox.holdsWork {
			return false
		}
		return true
	}
}

private struct LocalRun {
	private(set) var local: LocalErasure
	let began: Date
	let device: DeviceDefaults

	init(_ local: LocalErasure, of run: ErasureRun) {
		self.local = local
		self.began = run.began
		self.device = run.device
		device.mark(.running(.erasingLocally(local), began: began))
	}

	var resumable: ErasureRun {
		ErasureRun(progress: .erasingLocally(local), began: began, device: device)
	}

	mutating func advance(iCloud: ICloudErasure) {
		local.iCloud = iCloud
		device.mark(.running(.erasingLocally(local), began: began))
	}
}

extension ErasureOutcome {
	fileprivate init(refusal: any Error) {
		switch refusal as? CreditsFailure {
		case .unauthorized?:
			self = .creditsUnconfirmed
		case .rateLimited?, .unavailable?:
			self = .tryLater
		default:
			self = .notStarted
		}
	}
}
