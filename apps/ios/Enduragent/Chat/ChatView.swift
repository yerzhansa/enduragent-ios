import EnduragentCoach
import SwiftUI

struct ChatView: View {
	@Bindable var model: ShellModel

	var body: some View {
		NavigationStack(path: $model.navigation) {
			TranscriptView(model: model)
				.safeAreaInset(edge: .bottom, spacing: 0) {
					ComposerView(model: model)
				}
				#if DEBUG
					.overlay(alignment: .topLeading) {
						if let snapshot = model.chat {
							TurnProgressDebugView(snapshot: snapshot)
						}
					}
				#endif
				.navigationTitle(model.phrasebook.say(Catalog.chatViewTitle, [:]))
				.toolbar {
					ToolbarItem(placement: .topBarLeading) {
						Button {
							model.open(.history)
						} label: {
							Label(
								model.phrasebook.say(Catalog.archiveHistory, [:]),
								systemImage: "clock.arrow.circlepath")
						}
						.labelStyle(.iconOnly)
						.accessibilityIdentifier("chat.history")
					}
					ToolbarItem(placement: .topBarLeading) {
						Button {
							model.open(.settings)
						} label: {
							Label(
								model.phrasebook.say(Catalog.settingsTitle, [:]),
								systemImage: "gearshape")
						}
						.labelStyle(.iconOnly)
						.accessibilityIdentifier("chat.settings")
					}
					ToolbarItem(placement: .topBarTrailing) {
						Button {
							Task { await model.newConversation() }
						} label: {
							Label(
								model.phrasebook.say(Catalog.chatNewConversationLabel, [:]),
								systemImage: "square.and.pencil")
						}
						.labelStyle(.iconOnly)
						.accessibilityIdentifier("chat.newConversation")
					}
				}
				.navigationDestination(for: ShellDestination.self) { destination in
					switch destination {
					case .settings:
						SettingsView(model: model)
					case .history:
						HistoryView(model: model)
					case .archivedConversation(let ref):
						ArchivedConversationView(model: model, ref: ref)
					case .credits:
						CreditsView(model: model)
					case .training:
						TrainingSettingsView(model: model, settings: model.trainingSettings)
					#if DEBUG
						case .debug:
							SettingsDebugView(model: model)
						case .debugCredits:
							CreditsDebugView(
								coach: model.services.coach,
								deviceCheck: model.environment.deviceCheck,
								phrasebook: model.phrasebook)
						case .debugRecords:
							RecordSyncDebugView(probe: model.services.coach.recordSyncProbe())
						case .debugLanguage:
							LanguageView(model: model)
						case .session:
							SessionDebugView(model: model)
						case .debugLeases:
							LeasesDebugView(leases: model.services.leases)
					#endif
					}
				}
				.sheet(isPresented: $model.showLanguage) {
					NavigationStack {
						LanguageView(model: model)
							.toolbar {
								ToolbarItem(placement: .topBarTrailing) {
									Button {
										model.showLanguage = false
									} label: {
										Image(systemName: "xmark")
									}
									.accessibilityLabel(
										model.phrasebook.say(Catalog.chatViewCloseContext, [:])
									)
									.accessibilityIdentifier("language.close")
								}
							}
					}
					.presentationDetents([.fraction(LanguageSheetLayout.heightFraction)])
					.presentationDragIndicator(.visible)
				}
		}
	}
}
