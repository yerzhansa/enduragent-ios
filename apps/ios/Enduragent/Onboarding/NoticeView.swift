import EnduragentCoach
import SwiftUI

struct NoticeView: View {
	var model: ShellModel

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				Text(model.phrasebook.say(Catalog.onboardingNoticeHealth, [:]))
					.multilineTextAlignment(.center)
				Button(model.phrasebook.say(Catalog.commonContinue, [:])) {
					model.continueNotice()
				}
				.accessibilityIdentifier("notice.continue")
			}
			.padding()
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}
}
