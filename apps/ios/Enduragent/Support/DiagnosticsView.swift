import EnduragentCoach
import SwiftUI

struct DiagnosticsView: View {
	var model: ShellModel
	var support: SupportModel
	@State private var presented = false

	var body: some View {
		Form {
			Section {
				if let health = support.snapshot?.journal, let line = journalLine(health) {
					Text(notSaving(line, health))
						.accessibilityIdentifier("diagnostics.notSaving")
				}
				Text(say(Catalog.diagnosticsExplanation))
					.accessibilityIdentifier("diagnostics.explanation")
			}
			Section {
				Button {
					Task { await support.makeDiagnosticsFile() }
				} label: {
					Text(say(support.makeTitle)).frame(maxWidth: .infinity)
				}
				.disabled(!support.canMakeDiagnosticsFile)
				.accessibilityIdentifier("diagnostics.make")
				if let line = support.diagnosticsLine {
					Text(say(line))
						.accessibilityIdentifier("diagnostics.outcome")
				}
			}
		}
		.navigationTitle(say(Catalog.diagnosticsTitle))
		.navigationBarTitleDisplayMode(.inline)
		.task { await support.appear() }
		.sheet(isPresented: $presented) {
			if let file = support.sharing?.url {
				ShareSheet(file: file) { activity, completed, error in
					Task {
						await support.shareFinished(
							activityType: activity, completed: completed, error: error)
					}
				}
				.ignoresSafeArea()
				.interactiveDismissDisabled()
			}
		}
		.onChange(of: support.sharing) { _, handle in presented = handle != nil }
	}

	private func notSaving(_ line: CatalogKey, _ health: JournalHealth) -> String {
		guard case .notSaving(let since, _) = health else { return say(line) }
		return model.displayLocale.say(
			line,
			["time": .text(model.displayLocale.moment(since, in: model.services.clock.timeZone))])
	}

	private func say(_ key: CatalogKey) -> String { model.phrasebook.say(key) }
}
