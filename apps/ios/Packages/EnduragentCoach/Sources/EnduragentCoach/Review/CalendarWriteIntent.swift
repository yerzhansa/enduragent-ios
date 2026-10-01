import Foundation

struct CalendarWriteIntent: Sendable {
	let record: AthleteRecord
	var body: ReviewWriteBody
	let proposal: LiveProposal?
	var canceled = false

	var stamp: OperationStamp? {
		guard case .operation(let operation, let attempt) = record.cause else { return nil }
		return OperationStamp(
			operation: operation, attempt: attempt,
			binding: ActionBinding(account: record.account, zone: record.timeZone))
	}
}

extension Ledger {
	func calendarWrites(_ chat: ChatID) async throws(LedgerFailure) -> [CalendarWriteIntent] {
		let records = try await read(RecordQuery(scope: .synced([.reviewWrite]), chatId: chat))
			.records
		guard !records.isEmpty else { return [] }
		let local = try await read(ProposalPolicy.proposalQuery(chat)).records
		var intents: [CalendarWriteKey: CalendarWriteIntent] = [:]
		for record in records.sorted(by: { $0.hlc < $1.hlc }) {
			guard case .synced(.reviewWrite(let body)) = record.body else { continue }
			if var known = intents[body.key] {
				guard known.record.deviceId == record.deviceId,
					known.record.account == record.account
				else { continue }
				if known.body.evidence.dispatched {
					guard known.body.review == body.review, known.body.target == body.target else {
						continue
					}
					known.body.evidence = known.body.evidence.merging(body.evidence)
					intents[body.key] = known
					continue
				}
			}
			let retained = local.first { $0.ulid == body.review.ulid }
			let proposal: LiveProposal?
			if let retained, case .deviceLocal(.pendingProposal(let payload)) = retained.body {
				proposal = LiveProposal(
					cause: retained.cause, body: payload, account: retained.account,
					ulid: retained.ulid)
			} else {
				proposal = nil
			}
			let canceled =
				proposal.map { proposal in
					local.contains {
						guard case .deviceLocal(.proposalCleared(let cleared)) = $0.body else {
							return false
						}
						return cleared.nonce == proposal.body.nonce && cleared.reason == .canceled
					}
				} ?? false
			intents[body.key] = CalendarWriteIntent(
				record: record, body: body, proposal: proposal, canceled: canceled)
		}
		return intents.values.sorted { $0.record.hlc < $1.record.hlc }
	}
}
