import SwiftUI

struct RootView: View {
	@Bindable var model: ShellModel

	var body: some View {
		switch model.route {
		case .onboarding(.notice):
			NoticeView(model: model)
		case .onboarding(.connect):
			ConnectView(model: model)
		case .onboarding(.starter):
			StarterView(model: model)
		case .chat:
			ChatView(model: model)
		}
	}
}
