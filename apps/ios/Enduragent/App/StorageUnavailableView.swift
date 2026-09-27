import EnduragentCoach
import SwiftUI

struct StorageUnavailableView: View {
	let phrasebook: any Phrasebook
	let failure: any Error

	var body: some View {
		VStack(spacing: 16) {
			ForEach(Array(AthleteNotice.recordStoreUnavailable.enumerated()), id: \.offset) {
				Text($0.element.sentence(in: phrasebook))
					.multilineTextAlignment(.center)
			}
			#if DEBUG
				StorageFailureDebugView(failure: failure)
			#endif
		}
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("launch.storageUnavailable")
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}
