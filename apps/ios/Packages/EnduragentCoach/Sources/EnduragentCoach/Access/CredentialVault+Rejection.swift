import Foundation

extension CredentialVault {
	func refreshRejections() async {
		do {
			let page = try await ledger.read(
				RecordQuery(
					scope: .deviceLocal([.openRouterKeyRejected]), writtenBy: ledger.deviceId))
			guard page.skipped.isEmpty else { throw AccessUnavailable.recordStorageUnavailable }
			rejectedKeys.formUnion(
				page.records.compactMap { record in
					guard case .deviceLocal(.openRouterKeyRejected(let reference)) = record.body
					else {
						return nil
					}
					return reference
				})
			rejectionReadFailure = nil
		} catch {
			rejectionReadFailure = .recordStorageUnavailable
		}
	}

	func authorizeOpenRouterKey(_ reference: OpenRouterCredentialRef) throws(AccessUnavailable) {
		if let rejectionReadFailure { throw rejectionReadFailure }
		guard !rejectedKeys.contains(reference) else { throw .openRouterKeyRejected }
	}

	func authorizeInvocation(_ request: CompletionRequest) async throws(AccessUnavailable) {
		guard let reference = request.credential.openRouterReference else { return }
		await refreshRejections()
		try authorizeOpenRouterKey(reference)
	}

	func noteRejected(_ reference: OpenRouterCredentialRef) async throws(AccessUnavailable) {
		try await rejectionChanges.pass { () async throws(AccessUnavailable) in
			await refreshRejections()
			defer { accessUpdate.yield() }
			let alreadyRejected = rejectedKeys.contains(reference)
			rejectedKeys.insert(reference)
			if let rejectionReadFailure { throw rejectionReadFailure }
			guard !alreadyRejected else { return }
			let stamp = OperationStamp(
				operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
				attempt: AttemptID(ulid: await ledger.nextULID()),
				binding: ActionBinding(
					account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone))
			do {
				_ = try await ledger.commit(
					local: [.openRouterKeyRejected(reference)], stamp: stamp)
			} catch {
				rejectionReadFailure = .recordStorageUnavailable
				throw .recordStorageUnavailable
			}
		}
	}
}
