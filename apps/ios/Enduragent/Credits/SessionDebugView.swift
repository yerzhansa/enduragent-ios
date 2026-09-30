#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct SessionDebugView: View {
		@Bindable var model: ShellModel

		var body: some View {
			List {
				ForEach(SessionField.allCases, id: \.self) { field in
					SessionFieldRow(model: model, field: field)
				}
			}
			.navigationTitle("Session")
			.task { await model.refreshStatus() }
		}
	}

	private struct SessionFieldRow: View {
		@Bindable var model: ShellModel
		let field: SessionField
		@State private var text = ""
		@State private var outcome: String?

		var body: some View {
			Section(field.label) {
				Text(stored.isEmpty ? "—" : stored)
					.accessibilityIdentifier("session.\(field.name).stored")
				TextField(field.label, text: $text)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.accessibilityIdentifier("session.\(field.name).input")
				Button("Save") {
					Task { await save() }
				}
				.accessibilityIdentifier("session.\(field.name).save")
				if let outcome {
					Text(outcome)
						.accessibilityIdentifier("session.\(field.name).outcome")
				}
			}
		}

		private var stored: String {
			model.status?.session.text(for: field) ?? ""
		}

		private func save() async {
			let current = await model.refreshStatus().session
			let next: SessionSettings
			do {
				next = try current.replacing(field, with: text)
			} catch {
				outcome = error.sentence(in: model.phrasebook)
				return
			}
			do {
				try await model.saveSession(next)
				outcome = "Saved"
			} catch {
				switch error {
				case .notSaved: outcome = "Not saved"
				}
			}
		}
	}

	extension SessionField {
		fileprivate var name: String {
			switch self {
			case .historyBudgetRatio: "historyBudgetRatio"
			case .contextWindowOverride: "contextWindowOverride"
			}
		}

		fileprivate var label: String {
			switch self {
			case .historyBudgetRatio: "History budget ratio"
			case .contextWindowOverride: "Context window tokens"
			}
		}
	}
#endif
