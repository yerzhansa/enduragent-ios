import Foundation

public struct PendingProposal: Sendable, Equatable {
	public var chatId: ChatID
	public var nonce: Nonce
	public var summary: String
	public var description: String
	public var expiresAt: Date
}

public enum GatedToolInput: Sendable, Equatable {
	case createWorkout(date: CivilDate, workout: IntervalsWorkoutInput)
	case createStrengthWorkout(date: CivilDate, name: String, description: String)
	case deleteWorkout(eventId: EventID)
	case updateWorkout(UpdateWorkoutInput)
	case planSave(PlanHeadline)
}

public struct UpdateWorkoutInput: Sendable, Equatable {
	public var eventId: EventID
	public var date: CivilDate?
	public var name: String?
	public var description: String?
}

package enum ProposalLookup: Sendable, Equatable {
	case found(ProposalBody)
	case expired
	case mismatch
	case none
}

package enum ProposalPolicy {
	package static let ttl: Duration = TurnPolicy.proposalTTL
	package static let ttlSeconds: TimeInterval = 10 * 60

	package static func propose(
		chatId: ChatID,
		tool: GatedToolName,
		input: GatedToolInput,
		summary: String,
		description: String,
		now: Date,
		ledger: Ledger,
		stamp: OperationStamp
	) async throws -> PendingProposal {
		let records = try await ledger.read(proposalQuery(chatId)).records
		var bodies: [DeviceLocalRecordBody] = []
		if let live = UnionMerge.pendingProposal(records, chatId: chatId, now: now) {
			bodies.append(
				.proposalCleared(
					ProposalClearedBody(chatId: chatId, nonce: live.nonce, reason: .replaced)))
		}
		let nonce = Nonce()
		let expiresAt = now.addingTimeInterval(ttlSeconds)
		let body = ProposalBody(
			chatId: chatId,
			nonce: nonce,
			tool: tool,
			toolInput: input,
			summary: summary,
			description: description,
			expiresAt: expiresAt
		)
		bodies.append(.pendingProposal(body))
		_ = try await ledger.commit(local: bodies, stamp: stamp)
		return PendingProposal(
			chatId: chatId,
			nonce: nonce,
			summary: summary,
			description: description,
			expiresAt: expiresAt
		)
	}

	package static func take(
		chatId: ChatID,
		nonce: Nonce,
		ledger: Ledger,
		binding: ActionBinding,
		now: Date,
		run: @Sendable (GatedToolInput) async throws -> JSONValue
	) async throws -> ProposalLookup {
		let records = try await ledger.read(proposalQuery(chatId)).records
		if let live = UnionMerge.pendingProposal(records, chatId: chatId, now: now) {
			if live.nonce != nonce {
				return .mismatch
			}
			let stamp = OperationStamp(
				operation: .workoutChangeSet(
					ChangeSetID(ulid: await ledger.nextULID()), ChangeSetRevision(rawValue: 1)),
				attempt: AttemptID(ulid: await ledger.nextULID()),
				binding: binding
			)
			_ = try await ledger.commit(
				local: [
					.proposalCleared(
						ProposalClearedBody(chatId: chatId, nonce: nonce, reason: .executed))
				],
				stamp: stamp
			)
			_ = try await run(live.toolInput)
			return .found(live)
		}
		if latestUncleared(records, chatId: chatId) != nil {
			return .expired
		}
		return .none
	}

	package static func summary(for input: GatedToolInput) -> String {
		switch input {
		case .createWorkout(let date, let workout):
			return "Create workout \"\(workout.name)\" on \(date.rawValue)"
		case .createStrengthWorkout(let date, let name, _):
			return "Create strength workout \"\(name)\" on \(date.rawValue)"
		case .deleteWorkout:
			return "Delete a workout"
		case .updateWorkout(let update):
			var fields: [String] = []
			if let date = update.date {
				fields.append("date to \(date.rawValue)")
			}
			if let name = update.name {
				fields.append("name to \"\(name)\"")
			}
			if update.description != nil {
				fields.append("description")
			}
			let detail = fields.isEmpty ? "selected fields" : fields.joined(separator: ", ")
			return "Update workout — \(detail)"
		case .planSave(let headline):
			if headline.name.isEmpty {
				return "Save the training plan — replaces the current saved plan"
			}
			return "Save the training plan — replaces the current saved plan — \(headline.name)"
		}
	}

	package static func proposalQuery(_ chatId: ChatID) -> RecordQuery {
		RecordQuery(scope: .deviceLocal([.pendingProposal, .proposalCleared]), chatId: chatId)
	}

	private static func latestUncleared(_ records: [AthleteRecord], chatId: ChatID) -> ProposalBody?
	{
		let ordered = records.sorted { $0.hlc < $1.hlc }
		var cleared: Set<Nonce> = []
		for record in ordered {
			if case .deviceLocal(.proposalCleared(let body)) = record.body, body.chatId == chatId {
				cleared.insert(body.nonce)
			}
		}
		for record in ordered.reversed() {
			guard case .deviceLocal(.pendingProposal(let body)) = record.body, body.chatId == chatId
			else {
				continue
			}
			if cleared.contains(body.nonce) { continue }
			return body
		}
		return nil
	}
}
