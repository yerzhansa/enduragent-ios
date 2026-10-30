import Foundation

public enum ErasureStart: Sendable, Equatable {
	case begun
	case busy
}

public enum ErasureStep: String, Sendable, Equatable, CaseIterable {
	case iCloud
	case deviceRecords
	case files
	case keychain
}

public enum ErasureOutcome: Sendable, Equatable {
	case done
	case iCloudLater
	case notStarted
	case notFinished(ErasureStep)
}

extension Coach {
	public func beginErasure(_ defaults: DeviceDefaults) async -> ErasureStart {
		guard await isIdle() else { return .busy }
		defaults.mark(.started)
		return .begun
	}

	public func continueErasure(_ defaults: DeviceDefaults) async -> ErasureOutcome {
		switch defaults.erasure {
		case .started?:
			do {
				try await credits.erase()
			} catch {
				defaults.mark(nil)
				diagnostics.record(.erasureNotStarted(FailureCode(error)))
				return .notStarted
			}
			defaults.mark(.creditsErased)
		case .creditsErased?:
			break
		case .iCloudPending?, nil:
			return .notStarted
		}
		await lifecycle(.willTerminate)
		return await eraseFromThisPhone(defaults)
	}

	public func eraseReturningRows(_ defaults: DeviceDefaults) {
		guard defaults.erasure == .iCloudPending else { return }
		let ledger = ledger
		let diagnostics = diagnostics
		let clock = clock
		pendingErasure = Task {
			do {
				let saved = clock.now
				_ = try await ledger.erase(.synced, sparing: ledger.deviceId)
				if try await ledger.confirmSyncedExport(after: saved) { defaults.mark(nil) }
			} catch {
				diagnostics.record(.erasureUnconfirmed(FailureCode(error)))
			}
		}
	}

	private func eraseFromThisPhone(_ defaults: DeviceDefaults) async -> ErasureOutcome {
		let exported: Bool
		do {
			let erased = try await ledger.erase(.synced, sparing: nil)
			if erased == 0 {
				exported = true
			} else {
				exported = try await ledger.confirmSyncedExport(after: clock.now)
			}
		} catch {
			return stopped(at: .iCloud, error)
		}
		do {
			_ = try await ledger.erase(.deviceLocal, sparing: nil)
		} catch {
			return stopped(at: .deviceRecords, error)
		}
		do {
			try await support.eraseFiles()
			try await catalogs.eraseCache()
		} catch {
			return stopped(at: .files, error)
		}
		do {
			try await vault.eraseSecrets()
		} catch {
			return stopped(at: .keychain, error)
		}
		defaults.erase(keeping: exported ? nil : .iCloudPending)
		return exported ? .done : .iCloudLater
	}

	private func stopped(at step: ErasureStep, _ error: any Error) -> ErasureOutcome {
		diagnostics.record(.erasureNotFinished(step, FailureCode(error)))
		return .notFinished(step)
	}

	private func isIdle() async -> Bool {
		guard host.isIdle else { return false }
		for mailbox in mailboxes.values where await mailbox.holdsWork {
			return false
		}
		return true
	}
}
