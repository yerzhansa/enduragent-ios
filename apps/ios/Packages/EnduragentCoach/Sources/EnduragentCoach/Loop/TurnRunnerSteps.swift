import Foundation

extension TurnRunner {
	func generateStep(
		request: CompletionRequest,
		emit: @escaping @Sendable (CoachEvent) -> Void,
		streamed: inout String
	) async throws -> GenerateStep {
		let watchdog = ChatWatchdog()
		await watchdog.arm()
		do {
			let step = try await withThrowingTaskGroup(of: GenerateStep.self) { group in
				group.addTask {
					try await self.collect(request: request, watchdog: watchdog, emit: emit)
				}
				group.addTask {
					if let kind = await watchdog.fired() {
						throw kind
					}
					throw CancellationError()
				}
				guard let first = await group.nextResult() else {
					throw CancellationError()
				}
				await watchdog.disarm()
				group.cancelAll()
				while await group.nextResult() != nil {}
				switch first {
				case .success(let step):
					return step
				case .failure(let error):
					throw error
				}
			}
			streamed += step.text
			return step
		} catch {
			await watchdog.disarm()
			throw error
		}
	}

	func collect(
		request: CompletionRequest,
		watchdog: ChatWatchdog,
		emit: @escaping @Sendable (CoachEvent) -> Void
	) async throws -> GenerateStep {
		var text = ""
		var calls: [WireToolCall] = []
		var reason: FinishReason = .stop
		var usage = Usage(inputTokens: 0, outputTokens: 0, cost: nil)
		var finished = false
		let stream = transport.stream(request)
		for try await event in stream {
			try Task.checkCancellation()
			switch event {
			case .textDelta(let delta):
				if delta.isEmpty {
					continue
				}
				await watchdog.beat()
				text += delta
				emit(.textDelta(delta))
			case .toolCall(let call):
				await watchdog.beat()
				calls.append(call)
			case .heartbeat:
				await watchdog.beat()
			case .finished(let finishReason, let finishUsage):
				reason = finishReason
				usage = finishUsage
				finished = true
			}
		}
		_ = finished
		return GenerateStep(text: text, toolCalls: calls, reason: reason, usage: usage)
	}

	func runTools(
		_ calls: [WireToolCall],
		chatId: ChatID,
		state: TurnState,
		emit: @escaping @Sendable (CoachEvent) -> Void
	) async throws -> [(WireToolCall, ToolOutcome)] {
		try await withThrowingTaskGroup(of: (Int, WireToolCall, ToolOutcome).self) { group in
			for (index, call) in calls.enumerated() {
				group.addTask {
					emit(.toolStarted(name: call.name.rawValue, callId: call.id))
					let arguments: JSONValue
					do {
						arguments = try JSONValue.parse(call.arguments)
					} catch is DecodingError {
						emit(.toolFinished(name: call.name.rawValue, callId: call.id))
						return (
							index, call,
							.result(
								.object([
									"details": .string("Tool arguments were not valid JSON."),
									"error": .string("invalid_arguments"),
								])
							)
						)
					}
					let outcome = try await self.tools.execute(
						name: call.name,
						arguments: arguments,
						chatId: chatId,
						state: state
					)
					emit(.toolFinished(name: call.name.rawValue, callId: call.id))
					return (index, call, outcome)
				}
			}
			var rows: [(Int, WireToolCall, ToolOutcome)] = []
			for try await row in group {
				rows.append(row)
			}
			return rows.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
		}
	}

	func compact(
		wire: inout [WireMessage],
		budget: inout TurnBudget,
		chatId: ChatID,
		writer: inout RecordWriter
	) async throws {
		try budget.chargeGenerate()
		let keep = Array(wire.suffix(4))
		let dropped = Array(wire.dropLast(min(4, wire.count)))
		let request = CompletionRequest.openRouter(
			messages: [
				WireMessage(
					role: .system,
					content:
						"Summarize the conversation. Required headings: ## Athlete Profile, ## Training Status, ## Coach Stance, ## Discussion Context, ## Pending Questions.",
					toolCalls: [],
					toolCallId: nil
				),
				WireMessage(
					role: .user,
					content: dropped.map(\.content).joined(separator: "\n"),
					toolCalls: [],
					toolCallId: nil
				),
			],
			tools: [],
			deadline: TurnPolicy.compactionTimeout
		)
		var unused = ""
		let summary: String
		do {
			summary = try await generateStep(request: request, emit: { _ in }, streamed: &unused)
				.text
		} catch {
			summary = compactionStub(
				dropped.map { ChatMessage(role: .user, text: $0.content, civilDate: nil) })
		}
		if let first = keep.first {
			try await writer.append(
				.windowStart(
					WindowStartBody(
						chatId: chatId,
						firstIncludedUlid: ULID.generate(at: clock.now)
					)
				)
			)
			_ = first
		}
		try await writer.append(
			.compactionSummary(CompactionSummaryBody(chatId: chatId, markdown: summary))
		)
		var next: [WireMessage] = [
			WireMessage(
				role: .system,
				content: "[Previous conversation summary]\n\(summary)",
				toolCalls: [],
				toolCallId: nil
			)
		]
		next.append(contentsOf: keep)
		wire = next
	}

	func loadSnapshot() async throws -> AthleteSnapshot? {
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let oldest = today.adding(days: -(7 - 1))
		let days = try await intervals.fetchWellness(oldest: oldest, newest: today)
		guard let latest = days.last else {
			return nil
		}
		return AthleteSnapshot(fitness: latest.fitness, fatigue: latest.fatigue, form: latest.form)
	}

	func loadTranscript(chatId: ChatID) async throws -> Transcript {
		let records = try await store.fetch(
			RecordQuery(
				kinds: [.userMessage, .assistantMessage, .windowStart, .compactionSummary],
				chatId: chatId)
		)
		let ordered = records.sorted { $0.hlc < $1.hlc }
		let start = ordered.reversed().compactMap { record -> ULID? in
			if case .windowStart(let body) = record.body { return body.firstIncludedUlid }
			return nil
		}.first
		var messages: [ChatMessage] = []
		var ulids: [ULID] = []
		var lastDate: Date?
		for record in ordered {
			if let start, record.ulid.rawValue < start.rawValue {
				continue
			}
			switch record.body {
			case .userMessage(let body):
				messages.append(
					ChatMessage(role: .user, text: body.athleteText, civilDate: record.civilDate))
				ulids.append(record.ulid)
				lastDate = Date(timeIntervalSince1970: Double(record.hlc.wallMs) / 1000)
			case .assistantMessage(let body):
				messages.append(
					ChatMessage(role: .assistant, text: body.text, civilDate: record.civilDate))
				ulids.append(record.ulid)
				lastDate = Date(timeIntervalSince1970: Double(record.hlc.wallMs) / 1000)
			default:
				break
			}
		}
		return Transcript(messages: messages, ulids: ulids, lastDate: lastDate, windowStart: start)
	}

	func shouldDailyReset(last: Date?) -> Bool {
		guard let last else { return false }
		let resetAt = dailyResetDate(
			now: clock.now, timeZone: clock.timeZone, hour: TurnPolicy.dailyResetHour)
		guard last < resetAt else { return false }
		let grace = durationSeconds(TurnPolicy.dailyResetGrace)
		if clock.now.timeIntervalSince(last) < grace {
			return false
		}
		return true
	}
}

struct GenerateStep: Sendable {
	var text: String
	var toolCalls: [WireToolCall]
	var reason: FinishReason
	var usage: Usage
}

struct Transcript: Sendable {
	var messages: [ChatMessage]
	var ulids: [ULID]
	var lastDate: Date?
	var windowStart: ULID?

	func ulid(for message: ChatMessage) -> ULID? {
		guard let index = messages.firstIndex(of: message) else { return nil }
		return ulids[index]
	}
}

struct TurnFailure: Error {
	var message: String
}

struct RecordWriter {
	let store: any RecordLog
	let clock: any Clock
	var lastHLC: HybridLogicalClock?

	mutating func refreshClock() async throws {
		let synced = try await store.fetch(
			RecordQuery(kinds: [
				.userMessage, .assistantMessage, .windowStart, .compactionSummary,
				.coachReplyLanguage,
			])
		)
		let local = try await store.fetch(
			RecordQuery(
				kinds: [.flushPending, .pendingProposal, .proposalCleared],
				deviceLocalOnly: true
			)
		)
		lastHLC = (synced + local).map(\.hlc).max()
	}

	mutating func append(_ body: RecordBody) async throws {
		let tz =
			IANATimeZone(identifier: clock.timeZone.identifier) ?? .gmt
		let record = AthleteRecord(
			ulid: ULID.generate(at: clock.now),
			deviceId: store.deviceId,
			hlc: .tick(now: clock.now, deviceId: store.deviceId, last: lastHLC),
			timeZone: tz,
			civilDate: IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone),
			body: body
		)
		lastHLC = record.hlc
		try await store.append(record)
	}
}

func wireMessage(from message: ChatMessage) -> WireMessage {
	WireMessage(
		role: message.role == .user ? .user : .assistant,
		content: message.text,
		toolCalls: [],
		toolCallId: nil
	)
}

func encodeToolOutcome(_ outcome: ToolOutcome) -> String {
	switch outcome {
	case .result(let json):
		return json.canonicalDigestInput()
	case .pending(let proposal):
		return JSONValue.object([
			"pendingConfirmation": .bool(true),
			"summary": .string(proposal.summary),
		]).canonicalDigestInput()
	case .truncated(let notice, let tokens):
		return JSONValue.object([
			"truncated": .bool(true),
			"notice": .string(notice),
			"omittedSamples": .number(0),
			"estimatedTokens": .number(Double(tokens)),
		]).canonicalDigestInput()
	}
}

func compactionStub(_ dropped: [ChatMessage]) -> String {
	"""
	## Athlete Profile
	## Training Status
	## Coach Stance
	## Discussion Context
	\(dropped.map(\.text).joined(separator: "\n"))
	## Pending Questions
	"""
}

func shouldCompact(wire: [WireMessage], system: String) -> Bool {
	let estimated = wire.reduce(0) { $0 + estimateTokens($1.content) } + estimateTokens(system)
	let budget = TurnPolicy.contextWindowCap - 20_000
	return estimated > budget
}

func minDuration(_ lhs: Duration, _ rhs: Duration) -> Duration {
	lhs < rhs ? lhs : rhs
}

func durationSeconds(_ duration: Duration) -> TimeInterval {
	let components = duration.components
	return TimeInterval(components.seconds)
		+ TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
}

func dailyResetDate(now: Date, timeZone: TimeZone, hour: Int) -> Date {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = timeZone
	var parts = calendar.dateComponents([.year, .month, .day], from: now)
	parts.hour = hour
	parts.minute = 0
	parts.second = 0
	let todayReset = calendar.date(from: parts) ?? now
	if now < todayReset {
		return calendar.date(byAdding: .day, value: -1, to: todayReset) ?? todayReset
	}
	return todayReset
}
