import Foundation

@testable import EnduragentCoach

enum LiveSendAttempt {
	static func sending(_ action: ChangeAction, at now: Date) throws -> SendAttempt {
		let running = try review(of: [action], account: .unconnected, at: now).claimed(
			Claim(id: ClaimID(ulid: .generate(at: now)), action: .approve)
		).sending(at: now, seen: [:])
		guard case .running(let run) = running.stage, let attempt = run.sending else {
			throw LiveCheckStop(description: "the one-change review started no send attempt")
		}
		return attempt
	}

	static func review(of actions: [ChangeAction], account: TrainingAccount, at now: Date)
		throws -> WorkoutReview
	{
		let remaining = try actions.enumerated().map { position, action in
			try json(
				ChangeDocument(
					ReviewChange(
						id: ChangeID(ulid: .generate(at: now)), position: position, action: action))
			)
		}
		return try WorkoutReviewPayload.decode(
			Data(
				JSONValue.object([
					"id": .string(ULID.generate(at: now).rawValue), "revision": .number(1),
					"chat": .string("main"), "account": .string(account.storedValue),
					"turn": .string(ULID.generate(at: now).rawValue),
					"attempt": .string(ULID.generate(at: now).rawValue),
					"finished": .array([]), "remaining": .array(remaining), "kept": .array([]),
					"stage": try json(StageDocument(.waiting(.approval(.prepared)))),
				]).canonicalDigestInput().utf8))
	}

	private static func json(_ value: some Encodable) throws -> JSONValue {
		try JSONValue.parse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
	}
}

extension LiveCalendarRun {
	static let eventsPath = "/api/v1/athlete/0/events"

	mutating func loseEachAnswer() async {
		begin("lost add")
		let add = plan.lost
		guard record(add) else { return }
		let window = ReadRange.addWindow(around: add.payload.date)
		let added = await loseAnswer(
			of: .add(AddedWorkout(payload: add.payload, identity: add.identity)),
			requests: [
				"POST \(Self.eventsPath)/bulk?upsert=true&upsertOnUid=false&updatePlanApplied=false",
				"GET \(Self.eventsPath)?oldest=\(window.oldest.rawValue)&newest=\(window.newest.rawValue)",
			])
		guard case .seen(let id) = added else {
			fail("the settle read gave \(Self.text(added)), not seen")
			return
		}
		do {
			try ledger.record(calendar: add.externalID, event: id)
		} catch {
			fail(
				"the ledger did not record event \(id.rawValue): \(LiveCalendarSweep.describe(error))"
			)
		}
		begin("lost edit")
		guard let edited = await reviewed(id) else { return }
		let edit = await loseAnswer(
			of: .edit(EditedWorkout(target: edited, patch: plan.lostEdit)),
			requests: [
				"PUT \(Self.eventsPath)/\(id.rawValue)", "GET \(Self.eventsPath)/\(id.rawValue)",
			])
		if edit != .seen(id) {
			fail("the settle read gave \(Self.text(edit)), not seen as event \(id.rawValue)")
		}
		begin("lost delete")
		guard let deleted = await reviewed(id) else { return }
		let delete = await loseAnswer(
			of: .delete(DeletedWorkout(target: deleted)),
			requests: [
				"DELETE \(Self.eventsPath)/\(id.rawValue)", "GET \(Self.eventsPath)/\(id.rawValue)",
			])
		if delete != .gone {
			fail("the settle read gave \(Self.text(delete)), not gone")
		}
	}

	mutating func reviewed(_ id: EventID) async -> ReviewedTarget? {
		do {
			return .reviewed(id, try await client.fetchEvent(id: id).snapshot)
		} catch {
			fail("the read of event \(id.rawValue) failed: \(LiveCalendarSweep.describe(error))")
			return nil
		}
	}

	private mutating func loseAnswer(of action: ChangeAction, requests expected: [String]) async
		-> SettleRead?
	{
		let attempt: SendAttempt
		do {
			attempt = try LiveSendAttempt.sending(action, at: Date())
		} catch {
			fail("nothing was sent: \(LiveCalendarSweep.describe(error))")
			return nil
		}
		collect()
		dropNextAnswer()
		let answer = await CalendarWriter.send(attempt, on: client, now: Date())
		let read = await CalendarWriter.settle(attempt, on: client)
		let tapped = drained()
		for response in tapped {
			note("\(response.request) answered HTTP \(response.status)")
		}
		note(
			"With its answer dropped the write gave \(Self.text(answer)), and the settle read \(Self.text(read))."
		)
		if answer != .lost(.transport) {
			fail(
				"the write whose answer was dropped gave \(Self.text(answer)), not lost (transport)"
			)
		}
		if tapped.map(\.request) != expected {
			fail(
				"the write and its settle made \(tapped.map(\.request)), not \(expected)")
		}
		return read
	}

	static func text(_ answer: SendAnswer) -> String {
		switch answer {
		case .saved(let receipt): "saved event \(receipt.event.rawValue)"
		case .gone: "gone"
		case .refused(let status): "refused HTTP \(status.rawValue)"
		case .lost(let loss): "lost (\(loss))"
		}
	}

	static func text(_ read: SettleRead?) -> String {
		switch read {
		case .seen(let event): "seen as event \(event.rawValue)"
		case .gone: "gone"
		case .notSaved: "notSaved"
		case .readFailed: "readFailed"
		case nil: "nothing"
		}
	}
}
