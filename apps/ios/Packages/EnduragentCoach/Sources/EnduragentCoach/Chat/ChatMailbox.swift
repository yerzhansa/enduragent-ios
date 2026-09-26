import Foundation

package actor ChatMailbox {
	package let chatId: ChatID
	private let runner: TurnRunner
	private let memory: Memory
	private let ledger: Ledger
	private let clock: any Clock
	private let transport: any ModelTransport
	private var tail: Task<Void, Never>
	private var current: Task<Void, Never>?
	private var flushTask: Task<Void, Never>?
	package private(set) var busy = false

	package init(
		chatId: ChatID,
		runner: TurnRunner,
		memory: Memory,
		ledger: Ledger,
		clock: any Clock,
		transport: any ModelTransport
	) {
		self.chatId = chatId
		self.runner = runner
		self.memory = memory
		self.ledger = ledger
		self.clock = clock
		self.transport = transport
		self.tail = Task {}
	}

	package func send(_ text: String, language: LanguagePreference) -> AsyncThrowingStream<
		CoachEvent, Error
	> {
		AsyncThrowingStream { continuation in
			let task = Task {
				await self.serializedTurn(
					text: text, language: language, continuation: continuation)
			}
			continuation.onTermination = { termination in
				guard case .cancelled = termination else { return }
				task.cancel()
				Task { await self.stop() }
			}
		}
	}

	private func serializedTurn(
		text: String,
		language: LanguagePreference,
		continuation: AsyncThrowingStream<CoachEvent, Error>.Continuation
	) async {
		await enqueue {
			await self.performTurn(text: text, language: language, continuation: continuation)
		}
	}

	private func performTurn(
		text: String,
		language: LanguagePreference,
		continuation: AsyncThrowingStream<CoachEvent, Error>.Continuation
	) async {
		busy = true
		defer { busy = false }
		do {
			try await runner.run(text: text, chatId: chatId, language: language) { event in
				continuation.yield(event)
			}
			continuation.finish()
		} catch is CancellationError {
			continuation.finish()
		} catch {
			continuation.finish(throwing: error)
		}
	}

	package func stop() {
		current?.cancel()
	}

	package func reset() async throws {
		let previous = tail
		let next = Task {
			await previous.value
			try await self.resetBoundary()
		}
		tail = Task { _ = await next.result }
		current = tail
		try await next.value
	}

	private func resetBoundary() async throws(LedgerFailure) {
		let resetId = ResetID(ulid: await ledger.nextULID())
		let stamp = OperationStamp(
			operation: .conversationReset(resetId),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: ActionBinding(
				account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
		)
		_ = try await ledger.commit(
			local: [
				.flushPending(
					FlushPendingBody(chatId: chatId, trigger: .explicitReset, messageUlids: []))
			],
			stamp: stamp
		)
		let marker = await ledger.nextULID()
		_ = try await ledger.commit(
			synced: [
				.windowStart(
					WindowStartBody(
						chatId: chatId, firstIncludedUlid: marker,
						reason: .reset(.explicit(resetId))))
			],
			stamp: stamp
		)
	}

	package func runQueuedFlush() async {
		if let inFlight = flushTask {
			await inFlight.value
			return
		}
		let previous = tail
		let next = Task {
			await previous.value
			guard !Task.isCancelled else { return }
			try? await self.memory.flush(
				trigger: .softThreshold,
				chatId: self.chatId,
				transport: self.transport
			)
		}
		tail = next
		current = next
		flushTask = next
		await next.value
		if flushTask != nil {
			flushTask = nil
		}
	}

	private func enqueue(_ work: @escaping @Sendable () async -> Void) async {
		let previous = tail
		let next = Task {
			await previous.value
			guard !Task.isCancelled else { return }
			await work()
		}
		tail = next
		current = next
		await next.value
	}
}
