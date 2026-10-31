import EnduragentCoach
import SwiftUI

struct IntervalsKeyField: View {
	let phrasebook: CatalogPhrasebook
	@Binding var text: String

	var body: some View {
		SecureField(phrasebook.say(Catalog.onboardingConnectApiKey), text: $text)
			.autocorrectionDisabled()
			.textInputAutocapitalization(.never)
			.keyboardType(.asciiCapable)
	}
}
