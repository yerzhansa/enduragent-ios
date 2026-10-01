import Foundation

extension Coach {
	public func history() async throws(HistoryUnavailable) -> [ArchivedConversationSummary] {
		do {
			return try await ledger.history()
		} catch {
			throw .storageUnavailable
		}
	}

	public func observe(_ chat: ChatID) async -> AsyncStream<ChatSnapshot> {
		let feed = snapshotFeed(for: chat)
		do {
			return try await mailbox(for: chat).observe()
		} catch {
			diagnostics.record(.recoveryUnavailable(error))
			return feed.subscribe(
				from: ChatSnapshot(
					chat: chat, opening: .welcome, turns: [], activity: .idle, review: nil,
					notes: []))
		}
	}

	public func send(_ draft: Draft, to chat: ChatID) async throws(AcceptFailure) -> SendOutcome {
		let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return .ignoredBlank }
		let slash = SlashRouting.parse(text)
		switch slash?.route {
		case .languagePicker: return .showLanguagePicker
		case .resetConversation: return .newConversation(await startNewConversation(in: chat))
		case .modelTurn, nil: break
		}
		let mailbox: ChatMailbox
		do {
			mailbox = try await self.mailbox(for: chat)
		} catch {
			throw .storageUnavailable
		}
		return try await mailbox.accept(Draft(id: draft.id, text: text), slash: slash)
	}

	public func retry(_ turn: TurnID, in chat: ChatID) async throws(RetryRefusal) {
		let mailbox: ChatMailbox
		do {
			mailbox = try await self.mailbox(for: chat)
		} catch {
			throw .unknownTurn
		}
		try await mailbox.retry(turn)
	}

	public func stop(_ chat: ChatID) async {
		do {
			try await mailbox(for: chat).interrupt(.athleteStopped)
		} catch {
			diagnostics.record(.recoveryUnavailable(error))
		}
	}

	public func startNewConversation(in chat: ChatID) async -> ResetOutcome {
		do {
			return try await mailbox(for: chat).reset()
		} catch {
			return .notStarted(.local(.recordStorage))
		}
	}
}
