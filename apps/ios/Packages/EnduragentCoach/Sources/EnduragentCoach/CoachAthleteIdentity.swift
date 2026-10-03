import Foundation

extension Coach {
	func coachingTrainingConnection() async throws(AccessUnavailable) -> TrainingConnection {
		let training = try await vault.trainingConnection()
		if case .intervals(let connection, let athlete?) = training.account {
			do {
				try await recordVerifiedTrainingIdentity(connection: connection, athlete: athlete)
				if identityWriteFailure == connection { identityWriteFailure = nil }
			} catch {
				diagnostics.record(.recoveryUnavailable(error))
				identityWriteFailure = connection
				throw .recordStorageUnavailable
			}
		}
		return training
	}

	func recordTrainingIdentity(in status: TrainingStatus) async {
		guard case .connected(let summary, .intervals(let connection, let athlete?)) = status,
			case .available = summary.profile
		else { return }
		do {
			try await recordVerifiedTrainingIdentity(connection: connection, athlete: athlete)
			if identityWriteFailure == connection { identityWriteFailure = nil }
		} catch {
			diagnostics.record(.recoveryUnavailable(error))
			identityWriteFailure = connection
		}
	}

	package func recordVerifiedTrainingIdentity(
		connection: ConnectionID, athlete: IntervalsAthleteID
	)
		async throws(LedgerFailure)
	{
		try await identityChanges.pass { () throws(LedgerFailure) in
			let records = try await ledger.informationRecords()
			let observations = records.filter {
				$0.deviceId == ledger.deviceId && $0.body == .synced(.trainingIdentityObserved)
			}
			let account = TrainingAccount.intervals(connection: connection, athlete: athlete)
			if observations.isEmpty,
				let historical = InformationOwnership(records: records).firstAccount(
					on: ledger.deviceId),
				historical != account
			{
				try await appendTrainingObservation(historical)
			}
			guard !observations.contains(where: { $0.account == account }) else { return }
			try await appendTrainingObservation(account)
		}
	}

	private func appendTrainingObservation(_ account: TrainingAccount) async throws(LedgerFailure) {
		let id = await ledger.nextULID()
		_ = try await ledger.commit(
			synced: [.trainingIdentityObserved],
			stamp: OperationStamp(
				operation: .credentialChange(CredentialChangeID(ulid: id)),
				attempt: AttemptID(ulid: id),
				binding: ActionBinding(
					account: account, zone: AthleteCalendar(clock: clock).deviceZone)))
	}
}
