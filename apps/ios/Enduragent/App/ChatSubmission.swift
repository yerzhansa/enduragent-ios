import EnduragentCoach
import Foundation
import Observation

@MainActor
@Observable
final class ChatSubmission {
	var draft: Draft
	var slashListVisible = false
	private(set) var notSent = false
	private(set) var isSending = false
	private var resetAdmissionFailure: CoachFailure?
	let drafts: DraftStore

	init(defaults: UserDefaults) {
		drafts = DraftStore(defaults: defaults)
		draft = drafts.load(.main) ?? Draft(id: DraftID(), text: "")
	}

	func draftChanged(from previous: String) {
		if previous.isEmpty, !draft.text.isEmpty {
			draft = Draft(id: DraftID(), text: draft.text)
		}
		drafts.save(draft, for: .main)
		updateSlashList()
	}

	func fillSlash(_ command: SlashCommand) {
		draft.text = command.rawValue + " "
		drafts.save(draft, for: .main)
		updateSlashList()
	}

	private func updateSlashList() {
		slashListVisible = draft.text.hasPrefix("/") && !draft.text.contains(where: \.isWhitespace)
	}

	func isUncertain(_ reset: ResetStatus?) -> Bool {
		if case .failed? = reset { return true }
		return resetAdmissionFailure != nil
	}

	func send(using coach: Coach) async -> SendOutcome? {
		let sent = draft
		let text = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty, !isSending else { return nil }
		isSending = true
		defer { isSending = false }
		notSent = false
		slashListVisible = false
		do {
			let outcome = try await coach.send(Draft(id: sent.id, text: text), to: .main)
			switch outcome {
			case .accepted, .showLanguagePicker:
				clear(sent)
			case .newConversation(let admission):
				apply(admission, submitted: sent)
			case .ignoredBlank:
				break
			}
			return outcome
		} catch {
			switch error {
			case .storageUnavailable: notSent = true
			}
			return nil
		}
	}

	func newConversation(using coach: Coach) async {
		let sent = draft
		apply(await coach.startNewConversation(in: .main), submitted: sent)
	}

	private func apply(_ admission: ResetAdmission, submitted sent: Draft) {
		switch admission {
		case .accepted:
			resetAdmissionFailure = nil
			clear(sent)
		case .notStarted(let failure):
			resetAdmissionFailure = failure
		}
	}

	private func clear(_ sent: Draft) {
		guard draft.id == sent.id else { return }
		draft = Draft(id: DraftID(), text: draft == sent ? "" : draft.text)
		drafts.save(draft, for: .main)
	}
}
