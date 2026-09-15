import SwiftUI

struct ChatView: View {
	var model: ShellModel

	var body: some View {
		NavigationStack {
			Text("Coach")
				.navigationTitle("Coach")
		}
	}
}
