import Foundation

extension Memory {
	func runFlushGenerate(
		conversation: [ChatMessage],
		transport: any ModelTransport
	) async throws -> (writes: Int, ledgerAppends: Int) {
		let current = try await fullContext()
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		let fenced = PromptAssembly.wrapAthleteContext(
			current.isEmpty ? "No athlete data stored yet." : current)
		var messages: [WireMessage] = [
			WireMessage(
				role: .system, content: MemoryFlushPrompt.system, toolCalls: [], toolCallId: nil)
		]
		messages.append(contentsOf: conversation.map(memoryWireMessage(from:)))
		messages.append(
			WireMessage(
				role: .user,
				content: MemoryFlushPrompt.userPrompt(
					sections: SectionName.cyclingEffective,
					currentMemory: fenced,
					today: today.rawValue
				),
				toolCalls: [],
				toolCallId: nil
			)
		)
		let schemas = MemoryFlushPrompt.toolSchemas()
		var writes = 0
		var ledgerAppends = 0
		var steps = 0
		while steps < MemoryFlushPolicy.maxSteps {
			steps += 1
			let request = CompletionRequest.openRouter(
				messages: messages,
				tools: schemas,
				deadline: TurnPolicy.chatCallDeadline
			)
			let step = try await collectFlush(transport: transport, request: request)
			if step.calls.isEmpty {
				break
			}
			messages.append(
				WireMessage(
					role: .assistant, content: step.text, toolCalls: step.calls, toolCallId: nil)
			)
			for call in step.calls {
				let (payload, wroteSection, wroteLedger) = try await executeFlushTool(call)
				if wroteSection { writes += 1 }
				if wroteLedger { ledgerAppends += 1 }
				messages.append(
					WireMessage(role: .tool, content: payload, toolCalls: [], toolCallId: call.id)
				)
			}
		}
		return (writes, ledgerAppends)
	}

	func collectFlush(
		transport: any ModelTransport,
		request: CompletionRequest
	) async throws -> (text: String, calls: [WireToolCall], reason: FinishReason) {
		var text = ""
		var calls: [WireToolCall] = []
		var reason: FinishReason = .stop
		for try await event in transport.stream(request) {
			switch event {
			case .textDelta(let delta):
				text += delta
			case .toolCall(let call):
				calls.append(call)
			case .heartbeat:
				break
			case .finished(let finishReason, _):
				reason = finishReason
			}
		}
		_ = reason
		return (text, calls, reason)
	}

	func executeFlushTool(_ call: WireToolCall) async throws -> (String, Bool, Bool) {
		let arguments: JSONValue
		do {
			arguments = try JSONValue.parse(call.arguments)
		} catch is DecodingError {
			return (
				JSONValue.object(["error": .string("invalid_arguments")]).canonicalDigestInput(),
				false,
				false
			)
		}
		switch call.name {
		case .memoryWrite:
			let fields = arguments.objectFields
			guard let section = fields["section"]?.stringValue,
				let content = fields["content"]?.stringValue
			else {
				return (
					JSONValue.object(["error": .string("section_required")]).canonicalDigestInput(),
					false, false
				)
			}
			try await writeSection(SectionName(rawValue: section), content: content, source: .flush)
			return (JSONValue.object(["saved": .bool(true)]).canonicalDigestInput(), true, false)
		case .ledgerAppend:
			let fields = arguments.objectFields
			guard
				let dateRaw = fields["date"]?.stringValue,
				let date = CivilDate(rawValue: dateRaw),
				let kindRaw = fields["kind"]?.stringValue,
				let kind = LedgerKind(rawValue: kindRaw),
				let text = fields["text"]?.stringValue,
				!text.isEmpty
			else {
				return (
					JSONValue.object(["error": .string("invalid_event")]).canonicalDigestInput(),
					false,
					false
				)
			}
			let recorded = try await appendEvent(date: date, kind: kind, text: text, source: .flush)
			if recorded {
				return (
					JSONValue.object(["recorded": .bool(true)]).canonicalDigestInput(), false, true
				)
			}
			return (
				JSONValue.object(["duplicate": .bool(true), "recorded": .bool(false)])
					.canonicalDigestInput(),
				false,
				false
			)
		default:
			return (
				JSONValue.object(["error": .string("unsupported")]).canonicalDigestInput(), false,
				false
			)
		}
	}

	func oldestUnconsumedFlush(chatId: ChatID) async throws -> AthleteRecord? {
		let pending = try await store.fetch(
			RecordQuery(kinds: [.flushPending], chatId: chatId, deviceLocalOnly: true)
		).sorted { $0.hlc < $1.hlc }
		let consumed = try await consumedFlushIDs()
		return pending.first { record in
			!consumed.contains(record.ulid.rawValue)
		}
	}

	func consumedFlushIDs() async throws -> Set<String> {
		let records = try await store.fetch(RecordQuery(kinds: [.provenance]))
		var ids: Set<String> = []
		for record in records {
			guard case .provenance(let body) = record.body else { continue }
			if body.key.hasPrefix(MemoryFlushPolicy.consumedFlushKeyPrefix) {
				ids.insert(
					String(body.key.dropFirst(MemoryFlushPolicy.consumedFlushKeyPrefix.count)))
			}
		}
		return ids
	}

	func markConsumed(_ pending: AthleteRecord) async throws {
		let today = IntervalsPolicy.today(now: clock.now, timeZone: clock.timeZone)
		try await append(
			.provenance(
				ProvenanceBody(
					key: MemoryFlushPolicy.consumedFlushKeyPrefix + pending.ulid.rawValue,
					garmin: false,
					nonGarmin: false,
					unknown: false,
					contentSha256: sha256Hex(pending.ulid.rawValue)
				)
			),
			civilDate: today
		)
	}

	func loadFlushMessages(
		trigger: FlushTrigger,
		chatId: ChatID,
		pending: AthleteRecord?
	) async throws -> [ChatMessage] {
		let records = try await store.fetch(
			RecordQuery(kinds: [.userMessage, .assistantMessage, .windowStart], chatId: chatId)
		)
		let ignoreWindow =
			trigger == .trim || trigger == .preCompaction || trigger == .overflow
			|| trigger == .explicitReset
		if let pending, case .flushPending(let body) = pending.body, !body.messageUlids.isEmpty {
			let wanted = Set(body.messageUlids.map(\.rawValue))
			let byUlid = Dictionary(uniqueKeysWithValues: records.map { ($0.ulid.rawValue, $0) })
			var messages: [ChatMessage] = []
			for ulid in body.messageUlids {
				guard
					let record = byUlid[ulid.rawValue]
						?? records.first(where: { $0.ulid.rawValue == ulid.rawValue })
				else { continue }
				_ = wanted
				switch record.body {
				case .userMessage(let message):
					messages.append(
						ChatMessage(
							role: .user, text: message.athleteText, civilDate: record.civilDate))
				case .assistantMessage(let message):
					messages.append(
						ChatMessage(
							role: .assistant, text: message.text, civilDate: record.civilDate))
				default:
					break
				}
			}
			let current = UnionMerge.conversation(records, chatId: chatId, deviceId: store.deviceId)
			return mergeUnique(messages, current)
		}
		if ignoreWindow {
			return records.sorted { $0.hlc < $1.hlc }.compactMap { record in
				switch record.body {
				case .userMessage(let body) where body.chatId == chatId:
					return ChatMessage(
						role: .user, text: body.athleteText, civilDate: record.civilDate)
				case .assistantMessage(let body) where body.chatId == chatId:
					return ChatMessage(
						role: .assistant, text: body.text, civilDate: record.civilDate)
				default:
					return nil
				}
			}
		}
		return UnionMerge.conversation(records, chatId: chatId, deviceId: store.deviceId)
	}

	func mergeUnique(_ first: [ChatMessage], _ second: [ChatMessage]) -> [ChatMessage] {
		var seen: Set<String> = []
		var out: [ChatMessage] = []
		for message in first + second {
			let key = message.role.rawValue + "\u{1e}" + message.text
			if seen.insert(key).inserted {
				out.append(message)
			}
		}
		return out
	}

	func loadSnapshot() async throws -> MemorySnapshot {
		let sections = try await store.fetch(RecordQuery(kinds: [.memorySection]))
		let daily = try await store.fetch(RecordQuery(kinds: [.dailyNote]))
		let ledger = try await store.fetch(RecordQuery(kinds: [.ledgerEvent]))
		let journal = try await store.fetch(RecordQuery(kinds: [.journal]))
		let compaction = try await store.fetch(RecordQuery(kinds: [.compactionSummary]))
		return MemorySnapshot(
			sections: sections,
			daily: daily,
			ledgerRecords: ledger.sorted { $0.hlc < $1.hlc },
			journalRecords: journal.sorted { $0.hlc < $1.hlc },
			compaction: compaction,
			orphanNames: orphanNames(in: sections)
		)
	}

	func orphanNames(in records: [AthleteRecord]) -> [String] {
		let declared = SectionName.declaredNames
		var seen: Set<String> = []
		var names: [String] = []
		for record in records.sorted(by: { $0.hlc < $1.hlc }) {
			guard case .memorySection(let body) = record.body else { continue }
			if declared.contains(body.name.rawValue) { continue }
			if seen.insert(body.name.rawValue).inserted {
				names.append(body.name.rawValue)
			}
		}
		return names
	}

	func append(_ body: RecordBody, civilDate: CivilDate) async throws {
		let last = try await maxHLC()
		let tz =
			IANATimeZone(identifier: clock.timeZone.identifier) ?? .gmt
		let record = AthleteRecord(
			ulid: ULID.generate(at: clock.now),
			deviceId: store.deviceId,
			hlc: .tick(now: clock.now, deviceId: store.deviceId, last: last),
			timeZone: tz,
			civilDate: civilDate,
			body: body
		)
		try await store.append(record)
	}

	func maxHLC() async throws -> HybridLogicalClock? {
		let synced = RecordKind.allCases.filter { $0.locality == .synced }
		let local = RecordKind.allCases.filter { $0.locality == .deviceLocal }
		let first = try await store.fetch(RecordQuery(kinds: Set(synced)))
		let second = try await store.fetch(RecordQuery(kinds: Set(local), deviceLocalOnly: true))
		return (first + second).map(\.hlc).max()
	}
}
