import Foundation

struct MailboxQueue {
	private(set) var active: MailboxWork?
	private var waiting: [MailboxWork] = []

	var isEmpty: Bool { waiting.isEmpty }

	var resetting: Bool {
		active?.reset != nil || waiting.contains { $0.reset != nil }
	}

	func turns(includingActive: Bool) -> [TurnID] {
		let items = includingActive ? [active].compactMap { $0 } + waiting : waiting
		return items.compactMap(\.turn)
	}

	mutating func add(_ turn: TurnID, _: borrowing Admitted) -> Bool {
		append(.turn(turn))
	}

	mutating func add(_ reset: ResetID, _: borrowing Admitted) -> Bool {
		append(.reset(reset))
	}

	mutating func add(_ job: FlushJobID) -> Bool {
		append(.flush(job))
	}

	mutating func start() -> MailboxWork? {
		guard !waiting.isEmpty else { return nil }
		active = waiting.removeFirst()
		return active
	}

	mutating func finish() {
		active = nil
	}

	mutating func dropWaiting() -> [TurnID] {
		defer { waiting.removeAll { $0.reset == nil } }
		return turns(includingActive: false)
	}

	private mutating func append(_ item: MailboxWork) -> Bool {
		guard active != item, !waiting.contains(item) else { return false }
		waiting.append(item)
		return true
	}
}
