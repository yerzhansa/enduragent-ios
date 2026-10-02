import EnduragentCoach
import SwiftUI

struct TrainingConnectionResultView: View {
	var model: ShellModel
	let identifierPrefix: String
	let athleteIdentifier: String

	var body: some View {
		if let saved = model.trainingSettings.receipt?.saveNotice {
			Text(saved.sentence(in: model.phrasebook))
				.accessibilityIdentifier("\(identifierPrefix).saved")
		}
		if let summary = model.connected {
			if case .available(let profile) = summary.profile {
				Text(profile.name)
					.accessibilityIdentifier(athleteIdentifier)
				Text(
					model.phrasebook.say(
						Catalog.settingsTrainingAthlete, ["id": profile.athleteID.rawValue])
				)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.accessibilityIdentifier("\(identifierPrefix).athleteID")
				if let day = summary.today {
					metric(day.fitness, title: Catalog.onboardingConnectFitness, name: "fitness")
					metric(day.fatigue, title: Catalog.onboardingConnectFatigue, name: "fatigue")
					metric(day.form, title: Catalog.onboardingConnectForm, name: "form")
				}
			}
			if let notice = summary.notice {
				Text(notice.sentence(in: model.phrasebook))
					.accessibilityIdentifier("\(identifierPrefix).notice")
			}
			if let action = summary.action {
				Button(model.phrasebook.say(action.title)) {
					Task { await model.performTrainingDisplay(action) }
				}
				.accessibilityIdentifier("\(identifierPrefix).displayAction")
			}
		} else if case .unavailable? = model.status?.training {
			if let notice = model.status?.notice {
				Text(notice.sentence(in: model.phrasebook))
					.accessibilityIdentifier("\(identifierPrefix).notice")
			}
		} else {
			Text(model.phrasebook.say(Catalog.connectMissing))
				.accessibilityIdentifier("\(identifierPrefix).notice")
		}
	}

	@ViewBuilder
	private func metric(_ value: Double?, title: CatalogKey, name: String) -> some View {
		if let value {
			Text(model.phrasebook.say(title, ["value": WellnessDay.formattedNumber(value)]))
				.accessibilityIdentifier("\(identifierPrefix).\(name)")
		}
	}
}
