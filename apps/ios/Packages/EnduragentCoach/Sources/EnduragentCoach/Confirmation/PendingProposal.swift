import Foundation

package struct PendingProposal: Sendable, Equatable {
	package var chatId: ChatID
	package var nonce: Nonce
	package var summary: String
	package var description: String
	package var expiresAt: Date
	package var account: TrainingAccount
}

package enum GatedToolInput: Sendable, Equatable {
	case createWorkout(date: CivilDate, workout: IntervalsWorkoutInput)
	case createStrengthWorkout(date: CivilDate, name: String, description: String)
	case deleteWorkout(eventId: EventID)
	case updateWorkout(UpdateWorkoutInput)
	case planSave(PlanHeadline)
}

package struct UpdateWorkoutInput: Sendable, Equatable {
	package var eventId: EventID
	package var date: CivilDate?
	package var name: String?
	package var description: String?
}

package struct LiveProposal: Sendable, Equatable {
	package let cause: RecordCause
	package let body: ProposalBody
	package let account: TrainingAccount
	package let ulid: ULID
}

package enum ProposalPolicy {
	package static let ttlSeconds: TimeInterval = 10 * 60

	package static func save(
		chatId: ChatID, tool: GatedToolName, input: GatedToolInput, summary: String,
		description: String, now: Date, ledger: Ledger, stamp: OperationStamp,
		appliedWrites: Set<CalendarWriteID>
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
		let previous = records.sorted { $0.hlc < $1.hlc }.last {
			guard case .deviceLocal(.pendingProposal) = $0.body,
				case .operation(let origin, _) = $0.cause
			else { return false }
			return origin == stamp.operation
		}
		let writeID: CalendarWriteID
		if let previous, case .deviceLocal(.pendingProposal(let body)) = previous.body,
			let retained = body.writeID, !appliedWrites.contains(retained)
		{
			writeID = retained
		} else {
			writeID = CalendarWriteID()
		}
		let body = ProposalBody(
			writeID: writeID,
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
			expiresAt: expiresAt,
			account: stamp.binding.account
		)
	}

	package static func live(chatId: ChatID, ledger: Ledger, now: Date)
		async throws(LedgerFailure) -> LiveProposal?
	{
		let records = try await ledger.read(proposalQuery(chatId)).records
		return UnionMerge.pendingProposalRecord(records, chatId: chatId, now: now)
	}

	package static func clear(
		_ live: LiveProposal, reason: ProposalClearReason, ledger: Ledger, stamp: OperationStamp
	) async throws(LedgerFailure) {
		_ = try await ledger.commit(
			local: [
				.proposalCleared(
					ProposalClearedBody(
						chatId: live.body.chatId, nonce: live.body.nonce, reason: reason))
			],
			stamp: stamp
		)
	}

	package static func summary(for input: GatedToolInput) -> String {
		let phrasebook = LanguageTag.en.phrasebook
		switch ReviewSummary(input) {
		case .supplied(let text):
			return text
		case .createWorkout(let name, let date):
			return phrasebook.say(
				Catalog.coachProposalCreate, ["name": name, "date": date.rawValue])
		case .createStrengthWorkout(let name, let date):
			return phrasebook.say(
				Catalog.coachProposalCreateStrength, ["name": name, "date": date.rawValue])
		case .deleteWorkout:
			return phrasebook.say(Catalog.coachProposalDeleteFallback, [:])
		case .updateWorkout(let date, let name, let descriptionChanged):
			var fields: [String] = []
			if let date {
				fields.append(phrasebook.say(Catalog.coachProposalDate, ["date": date.rawValue]))
			}
			if let name {
				fields.append(phrasebook.say(Catalog.coachProposalName, ["name": name]))
			}
			if descriptionChanged {
				fields.append(phrasebook.say(Catalog.coachProposalDescription, [:]))
			}
			let detail =
				fields.isEmpty
				? phrasebook.say(Catalog.coachProposalSelectedFields, [:])
				: fields.joined(separator: ", ")
			return phrasebook.say(Catalog.coachProposalUpdateFallback, ["detail": detail])
		case .planSave(let name):
			return name.isEmpty
				? phrasebook.say(Catalog.coachProposalSavePlan, [:])
				: phrasebook.say(Catalog.coachProposalSavePlanDetail, ["detail": name])
		}
	}

	package static func proposalQuery(_ chatId: ChatID) -> RecordQuery {
		RecordQuery(scope: .deviceLocal([.pendingProposal, .proposalCleared]), chatId: chatId)
	}
}
