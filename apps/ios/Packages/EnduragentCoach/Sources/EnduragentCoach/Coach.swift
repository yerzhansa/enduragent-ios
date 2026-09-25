import Foundation

public actor Coach {
	public let memory: Memory
	public let planning: Planning

	private let sport: SportID
	private let transport: any ModelTransport
	private let intervals: any IntervalsClient
	private let ledger: Ledger
	private let clock: any Clock
	private var language: LanguagePreference
	private let tools: ToolRuntime
	private let runner: TurnRunner
	private var mailboxes: [ChatID: ChatMailbox]

	public init(
		sport: SportID,
		transport: any ModelTransport,
		intervals: any IntervalsClient,
		store: any RecordLog,
		clock: any Clock,
		language: LanguagePreference
	) {
		self.sport = sport
		self.transport = transport
		self.intervals = intervals
		let ledger = Ledger(log: store, clock: clock)
		self.ledger = ledger
		self.clock = clock
		self.language = language
		self.memory = Memory(ledger: ledger, clock: clock)
		let planning = Planning(store: store, intervals: intervals, clock: clock)
		self.planning = planning
		let tools = ToolRuntime(
			intervals: intervals, ledger: ledger, planning: planning, clock: clock)
		self.tools = tools
		self.runner = TurnRunner(
			transport: transport,
			intervals: intervals,
			ledger: ledger,
			clock: clock,
			tools: tools,
			planning: planning
		)
		self.mailboxes = [:]
	}

	public nonisolated func send(_ text: String, chatId: ChatID) -> AsyncThrowingStream<
		CoachEvent, Error
	> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let stream = await self.streamFromMailbox(text, chatId: chatId)
					for try await event in stream {
						continuation.yield(event)
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { termination in
				guard case .cancelled = termination else { return }
				task.cancel()
			}
		}
	}

	public func history(chatId: ChatID) async -> [ChatMessage] {
		(try? await loadHistory(chatId: chatId)) ?? []
	}

	public func pendingProposal(chatId: ChatID) async -> PendingProposal? {
		let records = (try? await ledger.read(ProposalPolicy.proposalQuery(chatId)).records) ?? []
		guard let current = UnionMerge.pendingProposal(records, chatId: chatId, now: clock.now)
		else {
			return nil
		}
		return PendingProposal(
			chatId: current.chatId,
			nonce: current.nonce,
			summary: current.summary,
			description: current.description,
			expiresAt: current.expiresAt
		)
	}

	public func confirm(chatId: ChatID, nonce: Nonce) async throws -> ConfirmOutcome {
		_ = sport
		_ = transport
		_ = intervals
		let tools = self.tools
		do {
			let lookup = try await ProposalPolicy.take(
				chatId: chatId,
				nonce: nonce,
				ledger: ledger,
				binding: binding,
				now: clock.now,
				run: { input in
					try await tools.rebuildConfirmed(input)
				}
			)
			switch lookup {
			case .found(let body):
				return .executed(summary: body.summary)
			case .expired:
				return .expired
			case .mismatch:
				return .mismatch
			case .none:
				return .none
			}
		} catch let error as IntervalsError {
			return .refused(message: error.details)
		} catch let error as InvalidWorkout {
			return .refused(message: error.message)
		} catch {
			return .failed(message: "\(error)")
		}
	}

	public func setCoachReplyLanguage(_ tag: LanguageTag?) async throws {
		let stamp = OperationStamp(
			operation: .preferenceChange(PreferenceChangeID(ulid: await ledger.nextULID())),
			attempt: AttemptID(ulid: await ledger.nextULID()),
			binding: binding
		)
		_ = try await ledger.commit(
			synced: [.coachReplyLanguage(CoachReplyLanguageBody(tag: tag))], stamp: stamp)
		language.coachReply = tag
	}

	#if DEBUG
		public nonisolated func recordSyncProbe() -> RecordSyncProbe {
			RecordSyncProbe(ledger: ledger, clock: clock)
		}
	#endif

	private var binding: ActionBinding {
		ActionBinding(account: .unconnected, zone: AthleteCalendar(clock: clock).deviceZone)
	}

	public func waitForMemoryFlush() async {
		for box in mailboxes.values {
			await box.runQueuedFlush()
		}
	}

	public func stop(chatId: ChatID) async {
		await mailbox(for: chatId).stop()
	}

	public func snapshot(chatId: ChatID) async -> ViewSeam {
		let transcript = await history(chatId: chatId)
		let pending = await pendingProposal(chatId: chatId)
		let box = mailbox(for: chatId)
		let busy = await box.busy
		let phase: TurnPhase
		if busy {
			phase = .streaming
		} else if pending != nil {
			phase = .awaitingConfirmation
		} else {
			phase = .idle
		}
		return ViewSeam(
			transcript: transcript,
			streamingText: "",
			leadFact: nil,
			commands: SlashCommand.all,
			pendingWrite: pending,
			planCards: [],
			phase: phase
		)
	}

	private func streamFromMailbox(_ text: String, chatId: ChatID) async -> AsyncThrowingStream<
		CoachEvent, Error
	> {
		await mailbox(for: chatId).send(text, language: language)
	}

	private func mailbox(for chatId: ChatID) -> ChatMailbox {
		if let existing = mailboxes[chatId] {
			return existing
		}
		let created = ChatMailbox(
			chatId: chatId,
			runner: runner,
			memory: memory,
			ledger: ledger,
			clock: clock,
			transport: transport
		)
		mailboxes[chatId] = created
		return created
	}

	private func loadHistory(chatId: ChatID) async throws -> [ChatMessage] {
		let page = try await ledger.read(
			RecordQuery(scope: ConversationFold.syncedScope, chatId: chatId))
		return ConversationFold.fold(chat: chatId, synced: page.records, device: ledger.deviceId)
			.current.messages
	}
}
