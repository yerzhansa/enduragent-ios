import Foundation
import Synchronization

package final class DrainLease: Sendable {
	package let generation: Int
	private let initiator: LeaseInitiator
	private let begun: Task<any ExecutionLease, Never>
	private let completed: Task<Void, Never>
	private let endings: AsyncStream<LeaseEnding>.Continuation
	private let failed = Mutex(false)

	package init(
		_ generation: Int, host: any ExecutionHost, chat: ChatID, initiator: LeaseInitiator,
		after priorEnding: Task<Void, Never>?,
		onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) {
		self.generation = generation
		self.initiator = initiator
		let begun = Task {
			await priorEnding?.value
			return await host.beginLease(
				LeaseRequest(chat: chat, initiatedBy: initiator), onExpiry: onExpiry)
		}
		let (stream, endings) = AsyncStream<LeaseEnding>.makeStream(bufferingPolicy: .unbounded)
		self.begun = begun
		self.endings = endings
		self.completed = Task {
			let lease = await begun.value
			var pending = stream.makeAsyncIterator()
			guard let ending = await pending.next() else { return }
			await lease.end(ending)
		}
	}

	package func covers(_ requested: LeaseInitiator) -> Bool {
		initiator == .athlete || requested == .recovery
	}

	package var kind: LeaseKind {
		get async { await begun.value.kind }
	}

	package func settle(_ settlement: Settlement?) {
		switch settlement {
		case .failed?, .savedWork?:
			failed.withLock { $0 = true }
		case .replied?, .interrupted?, nil:
			break
		}
	}

	package func finish() -> Task<Void, Never> {
		end(failed.withLock { $0 } ? .failed : .finished)
	}

	package func interrupt(_ cause: InterruptionCause) -> Task<Void, Never> {
		end(.interrupted(cause))
	}

	private func end(_ ending: LeaseEnding) -> Task<Void, Never> {
		endings.yield(ending)
		endings.finish()
		return completed
	}
}

package struct LeaseSlot: Sendable {
	private let host: any ExecutionHost
	private let chat: ChatID
	private(set) var current: DrainLease?
	private var generation = 0
	private var priorEnding: Task<Void, Never>?

	package init(host: any ExecutionHost, chat: ChatID) {
		self.host = host
		self.chat = chat
	}

	mutating func hold(
		_ initiator: LeaseInitiator,
		onExpiry: @escaping @Sendable (_ generation: Int, ExpiryCause) async -> Void
	) -> DrainLease {
		if let current, current.covers(initiator) {
			return current
		}
		if let current { priorEnding = current.finish() }
		generation += 1
		let begun = DrainLease(
			generation, host: host, chat: chat, initiator: initiator, after: priorEnding
		) { [generation] cause in
			await onExpiry(generation, cause)
		}
		current = begun
		return begun
	}

	mutating func end(_ ending: (DrainLease) -> Task<Void, Never>) -> Task<Void, Never>? {
		guard let current else { return priorEnding }
		self.current = nil
		priorEnding = ending(current)
		return priorEnding
	}

	func holds(_ generation: Int) -> Bool {
		current?.generation == generation
	}
}
