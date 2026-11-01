import Foundation

package struct CalendarWriteID: Hashable, Sendable, Codable {
	package let rawValue: UUID

	package init(rawValue: UUID = UUID()) { self.rawValue = rawValue }

	package var uid: String { rawValue.uuidString }
	package var externalID: String { "cycling-coach:\(uid)" }
}

package struct Receipt: Hashable, Sendable, Codable {
	package let event: EventID
	package let answeredAt: Date

	fileprivate init(event: EventID, answeredAt: Date) {
		self.event = event
		self.answeredAt = answeredAt
	}

	private enum CodingKeys: String, CodingKey {
		case event, answeredAt
	}

	package init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			event: EventID(rawValue: try values.decode(Int.self, forKey: .event)),
			answeredAt: Date(
				timeIntervalSince1970: try values.decode(Double.self, forKey: .answeredAt)))
	}

	package func encode(to encoder: any Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encode(event.rawValue, forKey: .event)
		try values.encode(answeredAt.timeIntervalSince1970, forKey: .answeredAt)
	}
}

package enum LostAnswer: Equatable, Sendable {
	case transport
	case unreadableBody
	case canceled
	case serverStatus(Int)
	case answerNamesOtherEvent
}

package enum SendAnswer: Equatable, Sendable {
	case saved(Receipt)
	case gone
	case refused(RefusalStatus)
	case lost(LostAnswer)
}

package enum SettleRead: Equatable, Sendable {
	case seen(EventID)
	case gone
	case notSaved
	case readFailed
}

package enum CalendarWriter {
	package static func send(_ attempt: SendAttempt, on client: any IntervalsClient, now: Date)
		async -> SendAnswer
	{
		let write = request(for: attempt.change.action)
		return classify(await client.write(write), of: write, at: now)
	}

	package static func settle(_ attempt: SendAttempt, on client: any IntervalsClient) async
		-> SettleRead
	{
		switch attempt.change.action {
		case .add(let add): await settle(add, on: client)
		case .edit(let edit): await settle(edit, on: client)
		case .delete(let delete): await settle(delete, on: client)
		}
	}

	private static func request(for action: ChangeAction) -> CalendarWrite {
		switch action {
		case .add(let add): .create(add.payload, identity: add.identity)
		case .edit(let edit): .update(edit.target.event, edit.patch)
		case .delete(let delete): .delete(delete.target.event)
		}
	}

	private static func classify(
		_ answer: IntervalsWriteAnswer, of write: CalendarWrite, at now: Date
	) -> SendAnswer {
		switch (answer, write) {
		case (.saved(let event), .create(let payload, let identity)):
			guard let event, payload.isCarried(by: event, as: identity) else {
				return .lost(.answerNamesOtherEvent)
			}
			return .saved(Receipt(event: event.id, answeredAt: now))
		case (.saved(let event), .update(let target, _)):
			guard event?.id == target else { return .lost(.answerNamesOtherEvent) }
			return .saved(Receipt(event: target, answeredAt: now))
		case (.saved, .delete(let target)):
			return .saved(Receipt(event: target, answeredAt: now))
		case (.httpStatus(404), .delete):
			return .gone
		case (.httpStatus(let status), _):
			guard let refusal = RefusalStatus(rawValue: status) else {
				return .lost(.serverStatus(status))
			}
			return .refused(refusal)
		case (.lost(.transport), _):
			return .lost(.transport)
		case (.lost(.unreadableBody), _):
			return .lost(.unreadableBody)
		case (.lost(.canceled), _):
			return .lost(.canceled)
		}
	}

	private static func settle(_ add: AddedWorkout, on client: any IntervalsClient) async
		-> SettleRead
	{
		let listed: [CalendarEvent]
		do {
			listed = try await client.listEvents(in: .addWindow(around: add.payload.date))
		} catch {
			return .readFailed
		}
		return switch add.onCalendar(listed) {
		case .absent: .notSaved
		case .found(let event): .seen(event)
		case .ambiguous: .readFailed
		}
	}

	private static func settle(_ edit: EditedWorkout, on client: any IntervalsClient) async
		-> SettleRead
	{
		let stored: WorkoutSnapshot
		do {
			stored = try await client.fetchEvent(id: edit.target.event).snapshot
		} catch let error as IntervalsError where error.status == 404 {
			return .notSaved
		} catch {
			return .readFailed
		}
		return edit.patch.isApplied(on: stored) ? .seen(edit.target.event) : .notSaved
	}

	private static func settle(_ delete: DeletedWorkout, on client: any IntervalsClient) async
		-> SettleRead
	{
		do {
			_ = try await client.fetchEvent(id: delete.target.event)
			return .notSaved
		} catch let error as IntervalsError where error.status == 404 {
			return .gone
		} catch {
			return .readFailed
		}
	}
}

extension CalendarPayload {
	fileprivate func isCarried(by event: CalendarEvent, as identity: CalendarWriteID) -> Bool {
		event.externalId == identity.externalID
			&& event.startDateLocal.prefix(10) == date.rawValue
			&& event.type == type.rawValue
			&& event.name == name
			&& WorkoutSnapshot.sameDescription(event.description, description)
	}
}

enum AddOnCalendar: Equatable, Sendable {
	case absent
	case found(EventID)
	case ambiguous
}

extension AddedWorkout {
	func onCalendar(_ listed: [CalendarEvent]) -> AddOnCalendar {
		let carrying = listed.filter { $0.externalId == identity.externalID }
		guard let event = carrying.first else { return .absent }
		return carrying.count == 1 ? .found(event.id) : .ambiguous
	}
}
