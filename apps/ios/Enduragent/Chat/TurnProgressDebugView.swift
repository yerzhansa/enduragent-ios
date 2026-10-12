#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct TurnProgressDebugView: View {
		let snapshot: ChatSnapshot
		@State private var observedTurn: TurnID?
		@State private var observedTools: Set<ToolName> = []

		var body: some View {
			VStack {
				Color.clear
					.accessibilityElement(children: .ignore)
					.accessibilityIdentifier("chat.turnProgress")
					.accessibilityLabel("Turn progress")
					.accessibilityValue("turns \(snapshot.turns.count) settled \(settledCount)")
				Color.clear
					.accessibilityElement(children: .ignore)
					.accessibilityIdentifier("chat.toolProgress")
					.accessibilityLabel("Observed tool calls")
					.accessibilityValue(
						"turns \(snapshot.turns.count) tools \(observedTools.map(\.rawValue).sorted().joined(separator: " "))"
					)
			}
			.frame(width: 1, height: 1)
			.allowsHitTesting(false)
			.onChange(of: snapshot.revision, initial: true) {
				if observedTurn != snapshot.turns.last?.id {
					observedTurn = snapshot.turns.last?.id
					observedTools.removeAll()
				}
				if case .processing(let processing) = snapshot.turns.last?.state,
					case .runningTools(let tools) = processing.activity
				{
					observedTools.formUnion(tools)
				}
			}
		}

		private var settledCount: Int {
			snapshot.turns.count { $0.state.isSettled }
		}
	}
#endif
