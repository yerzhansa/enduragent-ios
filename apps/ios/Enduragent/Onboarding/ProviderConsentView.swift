import EnduragentCoach
import SwiftUI

struct ProviderConsentView: View {
	var model: ShellModel

	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 24) {
					Text(model.phrasebook.say(Catalog.onboardingConsentTitle, [:]))
						.font(.title.bold())
						.accessibilityAddTraits(.isHeader)
					if let challenge = model.consentChallenge {
						Text(
							model.phrasebook.say(
								Catalog.onboardingConsentBody,
								[
									"model": challenge.target.entry.details.displayName,
									"provider": challenge.target.entry.details.provider.name,
								])
						)
						.accessibilityIdentifier("consent.body")
					}
					if model.consentNotSaved {
						Text(model.phrasebook.say(model.consentFailureKey))
							.foregroundStyle(.red)
							.accessibilityIdentifier("consent.error")
					}
					if case .onboarding(.consentDeferred) = model.route {
						Button(model.phrasebook.say(Catalog.onboardingConsentAccept, [:])) {
							Task { await model.acceptConsent() }
						}
						.accessibilityIdentifier("consent.resume")
					} else {
						Button(model.phrasebook.say(Catalog.onboardingConsentAccept, [:])) {
							Task { await model.acceptConsent() }
						}
						.buttonStyle(.borderedProminent)
						.accessibilityIdentifier("consent.accept")
						Button(model.phrasebook.say(Catalog.onboardingConsentDecline, [:])) {
							Task { await model.declineConsent() }
						}
						.accessibilityIdentifier("consent.decline")
					}
					#if DEBUG
						FixtureConsentDebugView(model: model)
					#endif
				}
				.disabled(model.isRecordingConsent)
				.padding(24)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
	}
}

extension ShellModel {
	var consentFailureKey: CatalogKey {
		if let choices = status.access.modelChoices, let challenge = consentChallenge,
			challenge.target.entry.id != choices.selected.id
		{
			return Catalog.reviewSaveFailed
		}
		return Catalog.onboardingConsentSaveFailed
	}
}
