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
					Text(model.phrasebook.say(Catalog.onboardingConsentBody, [:]))
						.accessibilityIdentifier("consent.body")
					if model.consentNotSaved {
						Text(model.phrasebook.say(Catalog.onboardingConsentSaveFailed, [:]))
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
							model.declineConsent()
						}
						.accessibilityIdentifier("consent.decline")
					}
				}
				.disabled(model.isRecordingConsent)
				.padding(24)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
	}
}
