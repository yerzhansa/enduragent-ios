import EnduragentCoach
import SwiftUI

struct SessionSettingsView: View {
	var model: ShellModel
	var session: SessionSettingsModel
	@Environment(\.dynamicTypeSize) private var textSize

	var body: some View {
		Form {
			ForEach(SessionField.allCases, id: \.self) { field in
				Section {
					row(field)
					if let rejection = session.rejections[field] {
						Text(rejection.sentence(in: model.phrasebook))
							.accessibilityIdentifier("session.\(field.name).rejection")
					}
				} footer: {
					Text(say(field.help))
						.accessibilityIdentifier("session.\(field.name).help")
				}
			}
			if session.isEditing {
				Section {
					if let line = model.sessionNotSavedLine {
						Text(line)
							.accessibilityIdentifier("session.saveFailed")
					}
					Button {
						Task { await model.saveSession() }
					} label: {
						wholeRow(Catalog.commonSave)
					}
					.accessibilityIdentifier("session.save")
					Button(role: .cancel) {
						session.cancel()
					} label: {
						wholeRow(Catalog.commonCancel)
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

	@ViewBuilder
	private func row(_ field: SessionField) -> some View {
		let label = Text(say(field.label))
			.accessibilityIdentifier("session.\(field.name).label")
		if textSize.isAccessibilitySize {
			VStack(alignment: .leading, spacing: 8) {
				label
				FieldBesideUnit {
					input(field, aligned: .leading)
					unit(field)
				}
			}
		} else {
			HStack {
				label
				input(field, aligned: .trailing)
				unit(field)
			}
		}
	}

	private func input(_ field: SessionField, aligned alignment: TextAlignment) -> some View {
		TextField(text: text(of: field), prompt: Text(prompt(for: field))) {
			Text(say(field.label))
		}
		.multilineTextAlignment(alignment)
		.keyboardType(.numbersAndPunctuation)
		.textInputAutocapitalization(.never)
		.autocorrectionDisabled()
		.accessibilityIdentifier("session.\(field.name).input")
	}

	private func unit(_ field: SessionField) -> some View {
		Text(say(field.unit))
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("session.\(field.name).unit")
	}

	private func wholeRow(_ title: CatalogKey) -> some View {
		Text(say(title))
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(.rect)
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

private struct FieldBesideUnit: Layout {
	private let spacing: CGFloat = 8

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		frames(within: proposal.width, subviews).reduce(CGRect.zero) { $0.union($1) }.size
	}

	func placeSubviews(
		in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
	) {
		for (subview, frame) in zip(subviews, frames(within: bounds.width, subviews)) {
			subview.place(
				at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
				proposal: ProposedViewSize(frame.size))
		}
	}

	private func frames(within width: CGFloat?, _ subviews: Subviews) -> [CGRect] {
		guard subviews.count == 2, let field = subviews.first, let unit = subviews.last else {
			return []
		}
		let unitSize = unit.sizeThatFits(.unspecified)
		let ideal = field.sizeThatFits(.unspecified).width + spacing + unitSize.width
		let available = width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
		guard ideal <= available else {
			let fieldHeight = field.sizeThatFits(ProposedViewSize(width: available, height: nil))
				.height
			let under = unit.sizeThatFits(ProposedViewSize(width: available, height: nil))
			return [
				CGRect(x: 0, y: 0, width: available, height: fieldHeight),
				CGRect(origin: CGPoint(x: 0, y: fieldHeight + spacing), size: under),
			]
		}
		let fieldWidth = available - spacing - unitSize.width
		let fieldHeight = field.sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
			.height
		let height = max(fieldHeight, unitSize.height)
		return [
			CGRect(x: 0, y: (height - fieldHeight) / 2, width: fieldWidth, height: fieldHeight),
			CGRect(
				origin: CGPoint(x: fieldWidth + spacing, y: (height - unitSize.height) / 2),
				size: unitSize),
		]
	}
}
