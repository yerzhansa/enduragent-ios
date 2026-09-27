import Foundation
import Synchronization

package final class DrainLease: Sendable {
	package let generation: Int
	private let initiator: LeaseInitiator
	private let begun: Task<any ExecutionLease, Never>
	private let commands: AsyncStream<Command>.Continuation
	private let tally = Mutex(LeaseTally())

	private enum Command: Sendable {
		case report(LeaseProgress)
		case end(LeaseEnding)
	}

	package init(
		_ generation: Int, host: any ExecutionHost, chat: ChatID, initiator: LeaseInitiator,
		onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) {
		self.generation = generation
		self.initiator = initiator
		let request = LeaseRequest(
			chat: chat, initiatedBy: initiator, title: Catalog.chatNoticeWorking)
		let begun = Task { await host.beginLease(request, onExpiry: onExpiry) }
		let (stream, commands) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
		self.begun = begun
		self.commands = commands
		Task {
			let lease = await begun.value
			for await command in stream {
				switch command {
				case .report(let progress):
					await lease.report(progress)
				case .end(let ending):
					await lease.end(ending)
					return
				}
			}
		}
	}

	package func covers(_ requested: LeaseInitiator) -> Bool {
		initiator == .athlete || requested == .recovery
	}

	package var kind: LeaseKind {
		get async { await begun.value.kind }
	}

	package func add(_ turn: TurnID) {
		report(tally.withLock { $0.add(turn) })
	}

	package func observe(_ progress: AttemptProgress) {
		guard case .activity(.generating(let step)) = progress else { return }
		report(tally.withLock { $0.step(step) })
	}

	package func settle(_ turn: TurnID, reply: ReplyText?) {
		report(tally.withLock { $0.settle(turn, reply: reply) })
	}

	package func finish() {
		end(.finished(tally.withLock { $0.notice }))
	}

	package func interrupt() {
		end(.interrupted)
	}

	private func report(_ progress: LeaseProgress) {
		commands.yield(.report(progress))
	}

	private func end(_ ending: LeaseEnding) {
		commands.yield(.end(ending))
		commands.finish()
	}
}

package struct LeaseSlot: Sendable {
	private let host: any ExecutionHost
	private let chat: ChatID
	private(set) var current: DrainLease?
	private var generation = 0

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
		current?.finish()
		generation += 1
		let begun = DrainLease(generation, host: host, chat: chat, initiator: initiator) {
			[generation] cause in
			await onExpiry(generation, cause)
		}
		current = begun
		return begun
	}

	mutating func end(_ ending: (DrainLease) -> Void) {
		guard let current else { return }
		self.current = nil
		ending(current)
	}

	func holds(_ generation: Int) -> Bool {
		current?.generation == generation
	}
}

private struct LeaseTally: Sendable {
	private var turns: Set<TurnID> = []
	private var settled: Set<TurnID> = []
	private var currentStep = 0
	private(set) var notice: CompletionNotice?

	mutating func add(_ turn: TurnID) -> LeaseProgress {
		turns.insert(turn)
		settled.remove(turn)
		return progress
	}

	mutating func step(_ step: Int) -> LeaseProgress {
		currentStep = step
		return progress
	}

	mutating func settle(_ turn: TurnID, reply: ReplyText?) -> LeaseProgress {
		turns.insert(turn)
		settled.insert(turn)
		switch reply {
		case .model(let text)?:
			notice = CompletionNotice(reply: text, turn: turn)
		case nil:
			break
		}
		return progress
	}

	private var progress: LeaseProgress {
		LeaseProgress(
			settledTurns: settled.count, totalTurns: turns.count, step: currentStep,
			stepLimit: TurnBudgetPolicy.npm.maxStepsPerInvocation)
	}
}
