import EnduragentCoach
import SwiftUI

struct SessionSettingsView: View {
	var model: ShellModel
	var session: SessionSettingsModel

	var body: some View {
		Form {
			ForEach(SessionField.allCases, id: \.self) { field in
				Section {
					HStack {
						Text(say(field.label))
						TextField(
							text: text(of: field), prompt: Text(prompt(for: field))
						) {
							Text(say(field.label))
						}
						.multilineTextAlignment(.trailing)
						.keyboardType(.numbersAndPunctuation)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.accessibilityIdentifier("session.\(field.name).input")
						Text(say(field.unit))
							.foregroundStyle(.secondary)
							.accessibilityIdentifier("session.\(field.name).unit")
					}
					if let rejection = session.rejections[field] {
						Text(rejection.sentence(in: model.phrasebook))
							.accessibilityIdentifier("session.\(field.name).rejection")
					}
				} footer: {
					Text(say(field.help))
				}
			}
			if session.isEditing {
				Section {
					if let line = model.sessionNotSavedLine {
						Text(line)
							.accessibilityIdentifier("session.saveFailed")
					}
					Button(say(Catalog.commonSave)) {
						Task { await model.saveSession() }
					}
					.accessibilityIdentifier("session.save")
					Button(say(Catalog.commonCancel), role: .cancel) {
						session.cancel()
					}
					.accessibilityIdentifier("session.cancel")
				}
			}
		}
		.disabled(session.isSaving)
		.navigationTitle(say(Catalog.settingsSessionTitle))
		.navigationBarTitleDisplayMode(.inline)
		.onDisappear { session.cancel() }
	}

	private func text(of field: SessionField) -> Binding<String> {
		let shown = session.drafts[field] ?? model.status.session.text(for: field)
		return Binding(
			get: { shown },
			set: { if $0 != shown { session.edit(field, to: $0) } })
	}

	private func prompt(for field: SessionField) -> String {
		switch field {
		case .historyBudgetRatio: SessionSettings.npmDefaults.text(for: field)
		case .contextWindowOverride: say(Catalog.settingsSessionContextWindowDefault)
		}
	}

	private func say(_ key: CatalogKey) -> String { model.phrasebook.say(key) }
}

extension ShellModel {
	var sessionNotSavedLine: String? {
		sessionSettings.notSaved ? phrasebook.say(Catalog.reviewSaveFailed) : nil
	}

	func saveSession() async {
		await sessionSettings.save(over: status.session)
	}
}

extension SessionField {
	fileprivate var name: String {
		switch self {
		case .historyBudgetRatio: "historyBudgetRatio"
		case .contextWindowOverride: "contextWindowOverride"
		}
	}

	fileprivate var label: CatalogKey {
		switch self {
		case .historyBudgetRatio: Catalog.settingsConversationFieldsHistoryTokenBudgetRatioLabel
		case .contextWindowOverride: Catalog.settingsSessionContextWindowLabel
		}
	}

	fileprivate var help: CatalogKey {
		switch self {
		case .historyBudgetRatio: Catalog.settingsConversationFieldsHistoryTokenBudgetRatioHelp
		case .contextWindowOverride: Catalog.settingsSessionContextWindowHelp
		}
	}

	fileprivate var unit: CatalogKey {
		switch self {
		case .historyBudgetRatio: Catalog.settingsSessionUnitsPercent
		case .contextWindowOverride: Catalog.settingsSessionUnitsTokens
		}
	}
}
