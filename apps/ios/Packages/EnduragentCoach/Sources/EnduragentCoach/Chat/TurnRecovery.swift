import Foundation

package struct RecoveryPlan: Sendable, Equatable {
	package var interrupt: [DeadClaim]
}

package struct DeadClaim: Sendable, Equatable {
	package let turn: TurnID
	package let attempt: AttemptID
	package let saved: WriteSummary
}

package enum TurnRecovery {
	package static let turnScope: RecordQuery.Scope = .synced([.userMessage, .turnSettled])
	package static let claimScope: RecordQuery.Scope = .deviceLocal([.turnClaim])
	package static let stampedWrites: RecordQuery.Scope = .synced([
		.memorySection, .dailyNote, .ledgerEvent,
	])

	package static func plan(
		turns: [TurnFacts], writes: [AttemptID: WriteSummary], device: DeviceID
	) -> RecoveryPlan {
		RecoveryPlan(
			interrupt: turns.filter { $0.origin == device }.flatMap { facts in
				facts.openClaims.map { claim in
					DeadClaim(
						turn: facts.turn, attempt: claim.attempt,
						saved: writes[claim.attempt, default: .none])
				}
			})
	}

	package static func writes(of attempts: Set<AttemptID>, in records: [AthleteRecord])
		-> [AttemptID: WriteSummary]
	{
		var commits: [AttemptID: [CommittedWrite]] = [:]
		for record in records {
			guard case .operation(_, let attempt) = record.cause, attempts.contains(attempt),
				let commit = CommittedWrite(stamped: record.body)
			else {
				continue
			}
			commits[attempt, default: []].append(commit)
		}
		return commits.mapValues(WriteSummary.init)
	}
}

extension CommittedWrite {
	fileprivate init?(stamped body: RecordBody) {
		switch body {
		case .synced(.memorySection), .synced(.dailyNote):
			self.init(tool: .memoryWrite)
		case .synced(.ledgerEvent):
			self.init(tool: .ledgerAppend)
		default:
			return nil
		}
	}
}
