import Foundation
import Synchronization

package final class DrainLease: Sendable {
	package let generation: Int
	private let initiator: LeaseInitiator
	private let begun: Task<any ExecutionLease, Never>
	private let completed: Task<Void, Never>
	private let commands: AsyncStream<Command>.Continuation
	private let tally = Mutex(LeaseTally())

	private enum Command: Sendable {
		case report(LeaseProgress)
		case updateLanguage(LanguageTag, CheckedContinuation<Void, Never>)
		case finish(LastReply?, failed: Bool)
		case interrupt(InterruptionCause)
	}

	package init(
		_ generation: Int, host: any ExecutionHost, chat: ChatID, initiator: LeaseInitiator,
		language: @escaping @Sendable () async -> LanguageTag,
		after priorEnding: Task<Void, Never>?,
		onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) {
		self.generation = generation
		self.initiator = initiator
		let begun = Task {
			await priorEnding?.value
			let spoken = await language()
			let request = LeaseRequest(
				chat: chat, initiatedBy: initiator, title: Catalog.chatNoticeWorking,
				language: spoken)
			return await host.beginLease(request, onExpiry: onExpiry)
		}
		let (stream, commands) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
		self.begun = begun
		self.commands = commands
		self.completed = Task {
			let lease = await begun.value
			for await command in stream {
				switch command {
				case .report(let progress):
					await lease.report(progress)
				case .updateLanguage(let spoken, let continuation):
					await lease.updateTitle(Catalog.chatNoticeWorking, language: spoken)
					continuation.resume()
				case .finish(let reply, let failed):
					let spoken = await language()
					let notice = reply.map {
						CompletionNotice(
							reply: $0.reply.sentence(in: CatalogPhrasebook(tag: spoken)),
							turn: $0.turn, language: spoken)
					}
					await lease.end(failed ? .failed(notice) : .finished(notice))
					return
				case .interrupt(let cause):
					await lease.end(.interrupted(cause))
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

	package func settle(_ turn: TurnID, settlement: Settlement?) {
		report(tally.withLock { $0.settle(turn, settlement: settlement) })
	}

	package func finish() -> Task<Void, Never> {
		end(tally.withLock { .finish($0.reply, failed: $0.failed) })
	}

	package func interrupt(_ cause: InterruptionCause) -> Task<Void, Never> {
		end(.interrupt(cause))
	}

	package func updateLanguage(_ language: LanguageTag) async {
		await withCheckedContinuation { continuation in
			if case .terminated = commands.yield(.updateLanguage(language, continuation)) {
				continuation.resume()
			}
		}
	}

	private func report(_ progress: LeaseProgress) {
		commands.yield(.report(progress))
	}

	private func end(_ command: Command) -> Task<Void, Never> {
		commands.yield(command)
		commands.finish()
		return completed
	}
}

package struct LeaseSlot: Sendable {
	private let host: any ExecutionHost
	private let chat: ChatID
	private let language: @Sendable () async -> LanguageTag
	private(set) var current: DrainLease?
	private var generation = 0
	private var priorEnding: Task<Void, Never>?

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
		if let current { priorEnding = current.finish() }
		generation += 1
		let begun = DrainLease(
			generation, host: host, chat: chat, initiator: initiator, language: language,
			after: priorEnding
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

private struct LeaseTally: Sendable {
	private var turns: Set<TurnID> = []
	private var settled: Set<TurnID> = []
	private var currentStep = 0
	private(set) var reply: LastReply?
	private(set) var failed = false

	mutating func add(_ turn: TurnID) -> LeaseProgress {
		turns.insert(turn)
		settled.remove(turn)
		return progress
	}

	mutating func step(_ step: Int) -> LeaseProgress {
		currentStep = step
		return progress
	}

	mutating func settle(_ turn: TurnID, settlement: Settlement?) -> LeaseProgress {
		turns.insert(turn)
		settled.insert(turn)
		switch settlement {
		case .replied(let reply, _)?:
			self.reply = LastReply(reply: reply, turn: turn)
		case .failed?, .savedWork?:
			failed = true
		case .interrupted?, nil:
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

private struct LastReply: Sendable {
	let reply: ReplyText
	let turn: TurnID
}
