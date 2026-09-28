#if DEBUG
	import SwiftUI

	struct FixtureFeedbackDebugView: View {
		let model: ShellModel
		let scrollToTail: () -> Void

		var body: some View {
			if let feedback = model.fixtureFeedback {
				Text(feedback)
					.accessibilityIdentifier("chat.error")
					.onChange(of: feedback, initial: true) {
						scrollToTail()
					}
			}
		}
	}
#endif
