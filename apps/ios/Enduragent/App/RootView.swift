import EnduragentCoach
import SwiftUI

struct RootView: View {
	@Bindable var model: ShellModel
	@Environment(\.scenePhase) private var scenePhase

	var body: some View {
		Group {
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
		.task {
			await model.appear()
		}
		.onChange(of: scenePhase, initial: true) { _, phase in
			guard let event = AppLifecycleEvent(phase) else { return }
			Task { await model.lifecycle.forward(event) }
		}
	}
}

extension AppLifecycleEvent {
	fileprivate init?(_ phase: ScenePhase) {
		switch phase {
		case .active:
			self = .becameActive
		case .inactive:
			self = .willResignActive
		case .background:
			self = .enteredBackground
		@unknown default:
			return nil
		}
	}
}
