#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct TurnProgressDebugView: View {
		let snapshot: ChatSnapshot

		var body: some View {
			Color.clear
				.frame(width: 1, height: 1)
				.accessibilityElement(children: .ignore)
				.accessibilityIdentifier("chat.turnProgress")
				.accessibilityLabel("Turn progress")
				.accessibilityValue("turns \(snapshot.turns.count) settled \(settledCount)")
				.allowsHitTesting(false)
		}

		private var settledCount: Int {
			snapshot.turns.count { $0.state.isSettled }
		}
	}
#endif
