import Foundation

extension CredentialVault {
	func refreshRejections() async {
		await rejectionChanges.pass { await persistRejections() }
	}

	private func persistRejections() async {
		do {
			let page = try await ledger.read(
				RecordQuery(
					scope: .deviceLocal([.openRouterKeyRejected]), writtenBy: ledger.deviceId))
			guard page.skipped.isEmpty else { throw AccessUnavailable.recordStorageUnavailable }
			let storedKeys = Set<OpenRouterCredentialRef>(
				page.records.compactMap { record in
					guard case .deviceLocal(.openRouterKeyRejected(let reference)) = record.body
					else {
						return nil
					}
					return reference
				})
			rejectedKeys.formUnion(storedKeys)
			let pending = rejectedKeys.subtracting(storedKeys)
			if !pending.isEmpty {
				let stamp = OperationStamp(
					operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
					attempt: AttemptID(ulid: await ledger.nextULID()),
					binding: ActionBinding(
						account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone))
				_ = try await ledger.commit(
					local: pending.map(DeviceLocalRecordBody.openRouterKeyRejected), stamp: stamp)
			}
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
			defer { accessUpdate.yield() }
			rejectedKeys.insert(reference)
			await persistRejections()
			if let rejectionReadFailure { throw rejectionReadFailure }
		}
	}
}
