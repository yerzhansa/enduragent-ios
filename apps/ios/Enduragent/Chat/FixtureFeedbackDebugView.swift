#if DEBUG
	import SwiftUI

	struct FixtureFeedbackDebugView: View {
		let model: ShellModel

		var body: some View {
			if let feedback = model.fixtureFeedback {
				Text(feedback)
					.accessibilityIdentifier("chat.error")
					.padding(.horizontal)
					.padding(.vertical, 8)
			}
		}
	}
#endif
