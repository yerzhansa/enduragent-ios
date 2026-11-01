import EnduragentCoach
import Foundation
import Observation

@MainActor
@Observable
final class SupportModel {
	private(set) var snapshot: SupportSnapshot?
	var draft = "" {
		didSet {
			if draft != oldValue { refusal = nil }
		}
	}
	private(set) var refusal: FeedbackRefusal?
	private(set) var sharing: DiagnosticsFileHandle?
	let about: About
	private let support: Support

	init(support: Support) {
		self.support = support
		about = support.about
	}

	func appear() async {
		var first = true
		for await next in await support.observe() {
			if first, draft.isEmpty, let kept = next.keptText { draft = kept }
			first = false
			snapshot = next
		}
	}

	func prefill(_ text: String) {
		if !text.isEmpty { draft = text }
	}

	func send() async {
		let sent = Support.trimmed(draft)
		do {
			finish(try await support.send(draft), sent: sent)
		} catch {
			refusal = error
		}
	}

	func tryAgain() async {
		let sent = Support.trimmed(draft)
		finish(await support.tryAgain(), sent: sent)
	}

	func makeDiagnosticsFile() async {
		guard case .ready(let handle) = await support.makeDiagnosticsFile() else { return }
		sharing = handle
	}

	func shareFinished(activityType: String?, completed: Bool, error: (any Error)?) async {
		guard let handle = sharing else { return }
		sharing = nil
		_ = await support.finishShare(
			handle,
			ShareOutcome.of(activityType: activityType, completed: completed, error: error))
	}

	var line: FeedbackLine {
		FeedbackLine.of(
			draft: draft, feedback: snapshot?.feedback, keptText: snapshot?.keptText,
			refusal: refusal)
	}

	var diagnosticsLine: CatalogKey? {
		snapshot.flatMap { diagnosticsLine(for: $0.diagnosticsFile) }
	}

	var canMakeDiagnosticsFile: Bool {
		switch snapshot?.diagnosticsFile {
		case .preparing?, .ready?: false
		case .idle?, DiagnosticsFileState.shared?, .saved?, .canceled?, .failed?, nil:
			sharing == nil
		}
	}

	var makeTitle: CatalogKey {
		guard case .failed(.couldNotWrite)? = snapshot?.diagnosticsFile else {
			return Catalog.diagnosticsMake
		}
		return Catalog.chatTranscriptRetry
	}

	private func finish(_ outcome: FeedbackOutcome?, sent: String) {
		if case .received? = outcome, Support.trimmed(draft) == sent { draft = "" }
	}

	private func diagnosticsLine(for state: DiagnosticsFileState) -> CatalogKey? {
		switch state {
		case .idle, .ready: nil
		case .preparing: Catalog.diagnosticsPreparing
		case DiagnosticsFileState.shared: Catalog.diagnosticsShared
		case .saved: Catalog.diagnosticsSaved
		case .canceled: Catalog.diagnosticsCanceled
		case .failed(.couldNotWrite): Catalog.diagnosticsFailed
		case .failed(.shareFailed): Catalog.diagnosticsShareFailed
		}
	}
}

struct FeedbackLine: Equatable {
	let sentence: CatalogKey?
	let arguments: [String: CatalogArgument]
	let button: FeedbackButton

	init(
		sentence: CatalogKey?, arguments: [String: CatalogArgument] = [:], button: FeedbackButton
	) {
		self.sentence = sentence
		self.arguments = arguments
		self.button = button
	}

	static func of(
		draft: String, feedback: FeedbackStatus?, keptText: String?, refusal: FeedbackRefusal?
	) -> FeedbackLine {
		if let refusal { return of(refusal) }
		let resend: FeedbackButton = Support.trimmed(draft) == keptText ? .tryAgain : .send
		switch feedback {
		case .idle?, nil: return FeedbackLine(sentence: nil, button: .send)
		case .sending?: return FeedbackLine(sentence: Catalog.feedbackSending, button: .sending)
		case .received?: return FeedbackLine(sentence: Catalog.feedbackReceived, button: .send)
		case .notSent(let reason)?: return FeedbackLine(sentence: reason.sentence, button: resend)
		case .notConfirmed?:
			return FeedbackLine(sentence: Catalog.feedbackNotConfirmed, button: resend)
		}
	}

	private static func of(_ refusal: FeedbackRefusal) -> FeedbackLine {
		switch refusal {
		case .empty:
			FeedbackLine(sentence: Catalog.feedbackRefusedEmpty, button: .send)
		case .containsNul:
			FeedbackLine(sentence: Catalog.feedbackRefusedInvalidCharacter, button: .send)
		case .tooLong:
			FeedbackLine(
				sentence: Catalog.feedbackRefusedTooLong,
				arguments: ["limit": .integer(FeedbackRefusal.limit)], button: .send)
		}
	}
}

enum FeedbackButton: Equatable {
	case send, tryAgain, sending
}

func journalLine(_ health: JournalHealth) -> CatalogKey? {
	switch health {
	case .saving: nil
	case .notSaving: Catalog.diagnosticsNotSaving
	}
}

extension NotSentReason {
	fileprivate var sentence: CatalogKey {
		switch self {
		case .noConnection: Catalog.feedbackNotSentNoConnection
		case .busy: Catalog.feedbackNotSentBusy
		case .refused: Catalog.feedbackNotSentRefused
		case .stopped: Catalog.feedbackNotSentStopped
		}
	}
}
