import EnduragentCoach
import Observation

@MainActor
@Observable
final class SessionSettingsModel {
	private(set) var drafts: [SessionField: String] = [:]
	private(set) var rejections: [SessionField: SessionSettingRejected] = [:]
	private(set) var notSaved = false
	private(set) var isSaving = false
	private let coach: Coach

	init(coach: Coach) {
		self.coach = coach
	}

	var isEditing: Bool { !drafts.isEmpty }

	func edit(_ field: SessionField, to text: String) {
		guard !isSaving else { return }
		drafts[field] = text
		rejections[field] = nil
	}

	func cancel() {
		drafts = [:]
		rejections = [:]
		notSaved = false
	}

	func save(over saved: SessionSettings) async {
		guard isEditing, !isSaving else { return }
		rejections = [:]
		notSaved = false
		var next = saved
		for field in SessionField.allCases {
			guard let text = drafts[field] else { continue }
			do {
				next = try next.replacing(field, with: text)
			} catch {
				rejections[field] = error
			}
		}
		guard rejections.isEmpty else { return }
		isSaving = true
		defer { isSaving = false }
		do {
			try await coach.setSession(next)
			drafts = [:]
		} catch {
			switch error {
			case .notSaved: notSaved = isEditing
			}
		}
	}
}
