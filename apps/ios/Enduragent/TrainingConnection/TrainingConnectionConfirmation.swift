import EnduragentCoach
import SwiftUI

struct TrainingConnectionConfirmation: ViewModifier {
	var model: ShellModel
	var settings: TrainingSettingsModel

	func body(content: Content) -> some View {
		content.alert(
			confirmationTitle, isPresented: Binding(get: { needsConfirmation }, set: { _ in })
		) {
			Button(say(Catalog.commonCancel), role: .cancel) {
				Task { await settings.keep() }
			}
			Button(confirmationAction, role: .destructive) {
				Task { await settings.confirm() }
			}
		} message: {
			Text(confirmationMessage)
		}
	}

	private var needsConfirmation: Bool {
		switch settings.state {
		case .confirmingOwner, .confirmingDisconnect: true
		case .viewing, .editing, .saving, .savingAway: false
		}
	}

	private var confirmationTitle: String {
		say(
			settings.state == .confirmingDisconnect
				? Catalog.settingsTrainingDisconnectTitle : Catalog.settingsTrainingSwitchTitle)
	}

	private var confirmationAction: String {
		say(
			settings.state == .confirmingDisconnect
				? Catalog.settingsTrainingDisconnect : Catalog.settingsTrainingSwitch)
	}

	private var confirmationMessage: String {
		if case .confirmingOwner(_, let current, let new) = settings.state {
			return model.phrasebook.say(
				Catalog.settingsTrainingSwitchDetail,
				["current": current.rawValue, "new": new.rawValue])
		}
		return say(Catalog.settingsTrainingDisconnectDetail)
	}

	private func say(_ key: CatalogKey) -> String { model.phrasebook.say(key) }
}
