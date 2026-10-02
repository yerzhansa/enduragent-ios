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
		case finish(LastReply?)
		case interrupt
	}

	package init(
		_ generation: Int, host: any ExecutionHost, chat: ChatID, initiator: LeaseInitiator,
		language: @escaping @Sendable () async -> LanguageTag,
		onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) {
		self.generation = generation
		self.initiator = initiator
		let begun = Task {
			let spoken = await language()
			let request = LeaseRequest(
				chat: chat, initiatedBy: initiator, title: Catalog.chatNoticeWorking,
				language: spoken)
			return await host.beginLease(request, onExpiry: onExpiry)
		}
		let (stream, commands) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
		self.begun = begun
		self.commands = commands
		Task {
			let lease = await begun.value
			for await command in stream {
				switch command {
				case .report(let progress):
					await lease.report(progress)
				case .finish(let reply):
					let spoken = await language()
					let notice = reply.map {
						CompletionNotice(
							reply: $0.reply.sentence(in: CatalogPhrasebook(tag: spoken)),
							turn: $0.turn, language: spoken)
					}
					await lease.end(.finished(notice))
					return
				case .interrupt:
					await lease.end(.interrupted)
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
		end(.finish(tally.withLock { $0.reply }))
	}

	package func interrupt() {
		end(.interrupt)
	}

	private func report(_ progress: LeaseProgress) {
		commands.yield(.report(progress))
	}

	private func end(_ command: Command) {
		commands.yield(command)
		commands.finish()
	}
}

package struct LeaseSlot: Sendable {
	private let host: any ExecutionHost
	private let chat: ChatID
	private let language: @Sendable () async -> LanguageTag
	private(set) var current: DrainLease?
	private var generation = 0

	package init(
		host: any ExecutionHost, chat: ChatID,
		language: @escaping @Sendable () async -> LanguageTag
	) {
		self.host = host
		self.chat = chat
		self.language = language
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
		let begun = DrainLease(
			generation, host: host, chat: chat, initiator: initiator, language: language
		) { [generation] cause in
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
	private(set) var reply: LastReply?

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
		if let reply {
			self.reply = LastReply(reply: reply, turn: turn)
		}
		return progress
	}

	private var progress: LeaseProgress {
		LeaseProgress(
			settledTurns: settled.count, totalTurns: turns.count, step: currentStep,
			stepLimit: TurnBudgetPolicy.npm.maxStepsPerInvocation)
	}
}

private struct LastReply: Sendable {
	let reply: ReplyText
	let turn: TurnID
}
