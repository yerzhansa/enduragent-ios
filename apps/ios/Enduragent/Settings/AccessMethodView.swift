import EnduragentCoach
import SwiftUI

struct AccessMethodView: View {
	var model: ShellModel

	var body: some View {
		List {
			Section {
				Button {
					Task { await model.chooseAccess(.useCredits) }
				} label: {
					choice(Catalog.creditsTitle, selected: model.selectedAccessMethod == .credits)
				}
				.accessibilityIdentifier("access.credits")
				.accessibilityAddTraits(model.selectedAccessMethod == .credits ? .isSelected : [])
				.disabled(model.isChangingAccess)
			}
			Section(model.phrasebook.say(Catalog.accessOpenRouterAccount)) {
				Button {
					Task { await model.chooseAccess(.signInToOpenRouter) }
				} label: {
					choice(
						Catalog.accessSignIn,
						selected: model.selectedAccessMethod == .openRouterAccount)
				}
				.accessibilityIdentifier("access.openRouter")
				.accessibilityAddTraits(
					model.selectedAccessMethod == .openRouterAccount ? .isSelected : []
				)
			}
			#if DEBUG
				FixtureSignInDebugView(model: model)
			#endif
			if let notice = model.accessNotice {
				Text(notice.sentence(in: model.displayLocale))
					.accessibilityIdentifier("access.notice")
			}
		}
		.navigationTitle(model.phrasebook.say(Catalog.accessTitle))
	}

	private func choice(_ title: CatalogKey, selected: Bool) -> some View {
		HStack {
			Text(model.phrasebook.say(title))
			Spacer()
			if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
		}
		.foregroundStyle(Color.primary)
	}
}

extension ShellModel {
	var selectedAccessMethod: AccessMethod { status.access.savedMethod ?? .credits }
	var accessNotice: AthleteNotice? { accessSettings.notice ?? status.access.notice }
	var isChangingAccess: Bool { accessSettings.isChanging }

	func chooseAccess(_ change: ModelAccessChange) async {
		await accessSettings.choose(change)
	}
}
