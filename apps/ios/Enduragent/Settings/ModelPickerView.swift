import EnduragentCoach
import SwiftUI

struct ModelPickerView: View {
	var model: ShellModel

	var body: some View {
		List {
			ForEach(model.modelPickerEntries, id: \.id) { entry in
				Button {
					Task { await model.chooseModel(entry.id) }
				} label: {
					HStack {
						Text(
							model.phrasebook.say(
								Catalog.setupAiModelVia,
								[
									"model": entry.details.displayName,
									"provider": entry.details.provider.name,
								]))
						Spacer()
						if model.modelChoices?.selected.id == entry.id {
							Image(systemName: "checkmark").accessibilityHidden(true)
						}
					}
					.foregroundStyle(Color.primary)
				}
				.accessibilityIdentifier("model.choice.\(entry.id.rawValue)")
				.accessibilityAddTraits(
					model.modelChoices?.selected.id == entry.id ? .isSelected : []
				)
				.disabled(model.isChangingAccess)
			}
			if let notice = model.accessNotice {
				Text(notice.sentence(in: model.displayLocale))
					.accessibilityIdentifier("model.notice")
			}
			#if DEBUG
				FixtureModelCatalogDebugView(model: model)
			#endif
		}
		.accessibilityIdentifier("model.choices")
		.navigationTitle(model.phrasebook.say(Catalog.settingsCoachChooseModel))
		.onAppear { model.accessSettings.dismiss() }
	}
}

extension ShellModel {
	var modelChoices: OpenRouterModelChoices? { status.access.modelChoices }

	var modelPickerEntries: [ModelCatalogEntry] {
		guard let choices = modelChoices else { return [] }
		let entries = choices.catalog.catalog.orderedEntries.map {
			$0.id == choices.selected.id ? choices.selected : $0
		}
		return entries.contains(where: { $0.id == choices.selected.id })
			? entries : [choices.selected] + entries
	}

	func chooseModel(_ id: ModelID) async {
		guard let choices = modelChoices, choices.selected.id != id else { return }
		await chooseAccess(.selectOpenRouterModel(id))
	}
}
