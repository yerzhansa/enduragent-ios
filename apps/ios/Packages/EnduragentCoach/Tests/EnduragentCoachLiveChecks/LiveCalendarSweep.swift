import Foundation

@testable import EnduragentCoach

struct CalendarSweepOutcome: Sendable, Equatable {
	var removed: [String: [EventID]] = [:]
	var left: [String] = []
}

enum LiveCalendarSweep {
	static func remove(
		_ externalIDs: [String], ledger: inout LiveSeedLedger, client: any IntervalsClient
	) async -> CalendarSweepOutcome {
		var outcome = CalendarSweepOutcome()
		for externalID in externalIDs.sorted() {
			guard let record = ledger.calendar[externalID] else { continue }
			do {
				let removed = try await remove(externalID, record: record, client: client)
				try ledger.record(removedCalendar: externalID)
				outcome.removed[externalID] = removed
			} catch {
				outcome.left.append("\(externalID): \(describe(error))")
			}
		}
		return outcome
	}

	private static func remove(
		_ externalID: String, record: SeedCalendarRecord, client: any IntervalsClient
	) async throws -> [EventID] {
		let window = try LiveSeedCalendar.window(around: record.date)
		var candidates = record.events
		candidates.formUnion(
			try await client.listEvents(in: window).filter { $0.externalId == externalID }.map(
				\.id))
		var removed: [EventID] = []
		for id in candidates.sorted(by: { $0.rawValue < $1.rawValue }) {
			guard let event = try await existing(id, client: client) else { continue }
			guard event.externalId == externalID else {
				throw LiveCheckStop(
					description:
						"event \(id.rawValue) carries \(event.externalId ?? "no external_id"), so it was not deleted"
				)
			}
			switch await client.write(.delete(id)) {
			case .saved, .httpStatus(404):
				removed.append(id)
			case let answer:
				throw LiveCheckStop(
					description: "DELETE of event \(id.rawValue) answered \(answer)")
			}
		}
		let stayed = try await client.listEvents(in: window).filter {
			$0.externalId == externalID
		}
		guard stayed.isEmpty else {
			throw LiveCheckStop(
				description:
					"the window still lists events \(stayed.map { String($0.id.rawValue) }.joined(separator: ", "))"
			)
		}
		for id in candidates where try await existing(id, client: client) != nil {
			throw LiveCheckStop(
				description: "event \(id.rawValue) still reads back after its delete")
		}
		return removed
	}

	static func existing(_ id: EventID, client: any IntervalsClient) async throws -> CalendarEvent?
	{
		do {
			return try await client.fetchEvent(id: id)
		} catch let error as IntervalsError where error.status == 404 {
			return nil
		}
	}

	static func describe(_ error: any Error) -> String {
		switch error {
		case let stop as LiveCheckStop: stop.description
		case let failure as IntervalsError: "\(failure.code): \(failure.details)"
		default: String(describing: error)
		}
	}
}
