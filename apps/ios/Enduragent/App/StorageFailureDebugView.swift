#if DEBUG
	import SwiftUI

	struct StorageFailureDebugView: View {
		let failure: any Error

		var body: some View {
			Text(String(describing: failure))
				.font(.footnote.monospaced())
				.foregroundStyle(.secondary)
		}
	}
#endif
