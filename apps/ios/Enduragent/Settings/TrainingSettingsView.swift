import EnduragentCoach
import SwiftUI

struct TrainingSettingsView: View {
	var model: ShellModel
	@Bindable var settings: TrainingSettingsModel

	var body: some View {
		Form {
			Section {
				if let saved = settings.receipt?.saveNotice {
					Text(saved.sentence(in: model.phrasebook))
						.accessibilityIdentifier("training.saved")
				}
				if let summary = model.connected {
					profile(summary)
					if let notice = summary.notice {
						Text(notice.sentence(in: model.phrasebook))
							.accessibilityIdentifier("training.notice")
					}
					if let action = summary.action {
						Button(say(action.title)) {
							Task { await model.performTrainingDisplay(action) }
						}
						.accessibilityIdentifier("training.displayAction")
					}
				} else if case .unavailable? = model.status?.training {
					if let notice = model.status?.notice {
						Text(notice.sentence(in: model.phrasebook))
							.accessibilityIdentifier("training.notice")
					}
				} else {
					Text(say(Catalog.connectMissing))
						.accessibilityIdentifier("training.notice")
				}
			}
			Section {
				if settings.isEditing {
					SecureField(say(Catalog.onboardingConnectApiKey), text: $settings.key)
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						.accessibilityIdentifier("training.apiKey")
					Button(
						say(
							model.connected == nil
								? Catalog.onboardingConnectAction : Catalog.settingsTrainingReplace)
					) {
						Task { await settings.replace() }
					}
					.accessibilityIdentifier("training.save")
					Button(say(Catalog.commonCancel), role: .cancel) {
						Task { await settings.keep() }
					}
					.accessibilityIdentifier("training.cancel")
				} else {
					Button(
						say(
							model.connected == nil
								? Catalog.onboardingConnectAction : Catalog.settingsTrainingReplace)
					) {
						settings.edit()
					}
					.accessibilityIdentifier("training.edit")
				}
				if model.connected != nil {
					Button(say(Catalog.settingsTrainingKeep)) {
						Task { await settings.keep() }
					}
					.accessibilityIdentifier("training.keep")
					Button(say(Catalog.settingsTrainingDisconnect), role: .destructive) {
						settings.requestDisconnect()
					}
					.accessibilityIdentifier("training.disconnect")
				}
			}
			.disabled(settings.isSaving)
			if settings.isSaving { ProgressView() }
		}
		.navigationTitle(say(Catalog.settingsTrainingTitle))
		.navigationBarTitleDisplayMode(.inline)
		.alert(confirmationTitle, isPresented: Binding(get: { needsConfirmation }, set: { _ in })) {
			Button(say(Catalog.commonCancel), role: .cancel) {
				Task { await settings.keep() }
			}
			Button(confirmationAction, role: .destructive) {
				Task { await settings.confirm() }
			}
		} message: {
			Text(confirmationMessage)
		}
		.onDisappear { settings.dismiss() }
	}

	@ViewBuilder
	private func profile(_ summary: IntervalsSummary) -> some View {
		if case .available(let profile) = summary.profile {
			Text(profile.name)
				.accessibilityIdentifier("training.athlete")
			Text(
				model.phrasebook.say(
					Catalog.settingsTrainingAthlete, ["id": profile.athleteID.rawValue])
			)
			.font(.footnote)
			.foregroundStyle(.secondary)
			.accessibilityIdentifier("training.athleteID")
			if let day = summary.today {
				metric(
					day.fitness, title: Catalog.onboardingConnectFitness,
					identifier: "training.fitness")
				metric(
					day.fatigue, title: Catalog.onboardingConnectFatigue,
					identifier: "training.fatigue")
				metric(day.form, title: Catalog.onboardingConnectForm, identifier: "training.form")
			}
		}
	}

	@ViewBuilder
	private func metric(_ value: Double?, title: CatalogKey, identifier: String) -> some View {
		if let value {
			Text(model.phrasebook.say(title, ["value": WellnessDay.formattedNumber(value)]))
				.accessibilityIdentifier(identifier)
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
