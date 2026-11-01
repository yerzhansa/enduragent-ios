import Foundation
import Synchronization

@testable import EnduragentCoach

struct LiveApprovalRecord: Sendable {
	let outcome: String
	let completed: Bool
	let creates: Int
	let problems: [String]
	let waitingAfter: Bool
}

final class LiveApprovalCalendar: Sendable {
	private struct State {
		var ledger: LiveSeedLedger
		var approving = false
		var created: [String] = []
		var creates = 0
		var problems: [String] = []
	}

	private let state: Mutex<State>

	private init(ledger: LiveSeedLedger) {
		state = Mutex(State(ledger: ledger))
	}

	static func open(_ file: URL?, for athlete: IntervalsAthleteID?) throws -> LiveApprovalCalendar
	{
		guard let file else {
			throw LiveCheckStop(description: "nothing was approved: the run names no seed ledger")
		}
		let ledger = try LiveSeedLedger(file: file)
		guard let recorded = ledger.athlete else {
			throw LiveCheckStop(
				description:
					"nothing was approved: the seed ledger names no athlete. Run make live-seed first."
			)
		}
		guard recorded == athlete?.rawValue else {
			throw LiveCheckStop(
				description:
					"nothing was approved: the seed ledger belongs to athlete \(recorded), but the key belongs to athlete \(athlete?.rawValue ?? "unknown")."
			)
		}
		return LiveApprovalCalendar(ledger: ledger)
	}

	func approve(_ token: ReviewControlToken, on coach: Coach) async throws -> LiveApprovalRecord {
		state.withLock { state in
			state.approving = true
			state.creates = 0
			state.problems = []
		}
		let outcome = await coach.decide(.approve(token), in: .main)
		let (creates, problems) = state.withLock { state in
			state.approving = false
			return (state.creates, state.problems)
		}
		let completed = if case .completed = outcome { true } else { false }
		return LiveApprovalRecord(
			outcome: "\(outcome)", completed: completed, creates: creates, problems: problems,
			waitingAfter: try await coach.desk.snapshot(chat: .main) != nil)
	}

	func write(_ write: CalendarWrite, through calendar: any IntervalsClient) async
		-> IntervalsWriteAnswer?
	{
		guard state.withLock({ $0.approving }) else { return nil }
		guard case .create(let payload, let identity) = write else {
			state.withLock { $0.problems.append("the approval sent \(write), not an add") }
			return .httpStatus(403)
		}
		do {
			try state.withLock { state in
				try state.ledger.record(calendar: identity.externalID, on: payload.date)
				state.created.append(identity.externalID)
			}
		} catch {
			state.withLock {
				$0.problems.append(
					"nothing was sent, because the ledger did not record \(identity.externalID): \(LiveCalendarSweep.describe(error))"
				)
			}
			return .httpStatus(403)
		}
		let answer = await calendar.write(write)
		state.withLock { state in
			state.creates += 1
			guard case .saved(let event?) = answer else { return }
			do {
				try state.ledger.record(calendar: identity.externalID, event: event.id)
			} catch {
				state.problems.append(
					"the ledger did not record event \(event.id.rawValue): \(LiveCalendarSweep.describe(error))"
				)
			}
		}
		return answer
	}

	func removeCreated(through calendar: any IntervalsClient) async -> [String] {
		var (ledger, created) = state.withLock { ($0.ledger, $0.created) }
		let outcome = await LiveCalendarSweep.remove(created, ledger: &ledger, client: calendar)
		state.withLock { state in
			state.ledger = ledger
			state.created = []
		}
		return outcome.left.map { "left on the calendar: \($0)" }
	}
}
