import Foundation

public actor Support {
	package nonisolated let log: DiagnosticsLog
	public nonisolated let about: About
	private let service: SupportService
	private let census: SupportCensus
	private let feed = SnapshotFeed<SupportSnapshot>()
	private let healthChanges: AsyncStream<JournalHealth>
	private var following: Task<Void, Never>?
	private var file: DiagnosticsFileState = .idle
	private var kept: KeptNote?
	private var feedback: FeedbackStatus
	private var running: Task<FeedbackSend, Never>?

	deinit {
		following?.cancel()
	}

	package init(log: DiagnosticsLog, service: SupportService, census: SupportCensus) {
		self.log = log
		about = About(app: service.app)
		self.service = service
		self.census = census
		healthChanges = log.healthChanges()
		do {
			try service.shareFolder.sweep()
		} catch {
			log.record(.diagnosticsFileFailed(.couldNotWrite, FailureCode(error)))
		}
		let relaunched = Self.relaunched(from: service.keptNotes, log: log)
		kept = relaunched
		feedback = relaunched.map { FeedbackStatus(kept: $0.phase) } ?? .idle
	}

	public func observe() -> AsyncStream<SupportSnapshot> {
		if following == nil {
			let changes = healthChanges
			following = Task { [weak self] in
				for await _ in changes {
					guard let self else { return }
					await self.publish()
				}
			}
		}
		return feed.subscribe(from: snapshot)
	}

	public func send(_ draft: String) async throws(FeedbackRefusal) -> FeedbackOutcome {
		try await sendNote(draft).outcome
	}

	package func sendNote(_ draft: String) async throws(FeedbackRefusal) -> FeedbackSend {
		let text = try FeedbackText(validating: draft)
		if let running { return await running.value }
		guard let kept, kept.note.revised(to: text) == kept.note else {
			let note = FeedbackNote.first(text)
			keep(KeptNote(note: note, phase: .ready))
			return await deliver(note, prior: nil)
		}
		return await deliver(kept.note, prior: kept.phase)
	}

	public nonisolated static func trimmed(_ draft: String) -> String {
		FeedbackText.trimmedAsJavaScript(draft)
	}

	public func tryAgain() async -> FeedbackOutcome? {
		if let running { return await running.value.outcome }
		guard let kept else { return nil }
		return await deliver(kept.note, prior: kept.phase).outcome
	}

	private func deliver(_ note: FeedbackNote, prior: KeptPhase?) async -> FeedbackSend {
		keep(KeptNote(note: note, phase: .sending))
		feedback = .sending
		publish()
		let delivery = Task { await settle(note, prior: prior) }
		running = delivery
		return await delivery.value
	}

	private func settle(_ note: FeedbackNote, prior: KeptPhase?) async -> FeedbackSend {
		let answers = await service.feedback.deliver(note)
		let outcome = FeedbackDelivery.settle(prior: prior, answers: answers)
		switch outcome {
		case .received:
			forget()
			feedback = .received
		case .notSent(let reason):
			settled(note, as: .notSent(reason), answers: answers)
		case .notConfirmed:
			settled(note, as: .notConfirmed, answers: answers)
		}
		running = nil
		publish()
		return FeedbackSend(id: note.id, answers: answers, outcome: outcome)
	}

	private func settled(_ note: FeedbackNote, as phase: KeptPhase, answers: [AttemptAnswer]) {
		keep(KeptNote(note: note, phase: phase))
		log.record(.feedbackNotDelivered(answers: answers))
		feedback = FeedbackStatus(kept: phase)
	}

	private func keep(_ note: KeptNote) {
		kept = note
		Self.save(note, to: service.keptNotes, log: log)
	}

	private func forget() {
		kept = nil
		do {
			try service.keptNotes.clear()
		} catch {
			log.record(.feedbackNoteUnsaved(FailureCode(error)))
		}
	}

	private static func relaunched(from storage: any KeptNoteStorage, log: DiagnosticsLog)
		-> KeptNote?
	{
		let loaded: KeptNote?
		do {
			loaded = try storage.load()
		} catch {
			log.record(.feedbackNoteUnsaved(FailureCode(error)))
			return nil
		}
		guard var kept = loaded else { return nil }
		let shown = kept.phase.afterRelaunch
		guard shown != kept.phase else { return kept }
		kept.phase = shown
		save(kept, to: storage, log: log)
		return kept
	}

	private static func save(_ kept: KeptNote, to storage: any KeptNoteStorage, log: DiagnosticsLog)
	{
		do {
			try storage.save(kept)
		} catch {
			log.record(.feedbackNoteUnsaved(FailureCode(error)))
		}
	}

	public func makeDiagnosticsFile() async -> DiagnosticsFileState {
		if case .preparing = file { return file }
		if case .ready(let earlier) = file { remove(earlier) }
		show(.preparing)
		let facts = await census.status()
		let records = await census.records()
		let made = log.clock.now
		let contents = DiagnosticsFile(
			made: made, app: about.app, device: service.device, facts: facts, records: records,
			journal: log.health, lines: log.window(endingAt: made))
		do {
			show(
				.ready(
					try service.shareFolder.write(
						try contents.encoded(), named: contents.name(in: log.clock.timeZone),
						id: ULID.generate(at: made))))
		} catch {
			log.record(.diagnosticsFileFailed(.couldNotWrite, FailureCode(error)))
			show(.failed(.couldNotWrite))
		}
		return file
	}

	public func finishShare(_ handle: DiagnosticsFileHandle, _ outcome: ShareOutcome)
		-> DiagnosticsFileState
	{
		guard case .ready(handle) = file else { return file }
		remove(handle)
		show(outcome.state)
		return file
	}

	private func remove(_ handle: DiagnosticsFileHandle) {
		do {
			try service.shareFolder.remove(handle)
		} catch {
			log.record(.diagnosticsFileFailed(.couldNotWrite, FailureCode(error)))
		}
	}

	private func show(_ state: DiagnosticsFileState) {
		file = state
		publish()
	}

	private func publish() {
		feed.publish(snapshot)
	}

	private var snapshot: SupportSnapshot {
		SupportSnapshot(
			feedback: feedback, keptText: kept?.note.text.trimmed, diagnosticsFile: file,
			journal: log.health)
	}
}

public struct SupportSnapshot: Sendable, Equatable {
	public let feedback: FeedbackStatus
	public let keptText: String?
	public let diagnosticsFile: DiagnosticsFileState
	public let journal: JournalHealth
}

public enum FeedbackStatus: Sendable, Equatable {
	case idle
	case sending
	case received
	case notSent(NotSentReason)
	case notConfirmed

	init(kept: KeptPhase) {
		switch kept {
		case .ready: self = .notSent(.stopped)
		case .sending: self = .sending
		case .notSent(let reason): self = .notSent(reason)
		case .notConfirmed: self = .notConfirmed
		}
	}
}

package struct FeedbackSend: Sendable, Equatable {
	package let id: FeedbackID
	package let answers: [AttemptAnswer]
	package let outcome: FeedbackOutcome
}

public struct About: Sendable, Equatable {
	public static let privacyPolicy: URL = {
		guard let url = URL(string: "https://enduragent.icu/privacy.html") else {
			fatalError("The privacy policy URL is invalid")
		}
		return url
	}()

	public let app: AppIdentity
}

extension SupportCensus {
	init(ledger: Ledger, preferences: CoachPreferences, vault: CredentialVault) {
		self.init(
			status: {
				StatusFacts(
					access: AccessKind(await preferences.accessStatus()),
					training: ConnectionKind(await vault.storedTrainingStatus()),
					language: LanguageCode(await preferences.load().language))
			},
			records: { await ledger.census() })
	}
}
