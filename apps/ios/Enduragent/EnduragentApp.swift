import SwiftUI

@main
struct EnduragentApp: App {
	@State private var model = ShellModel(builder: ServicesBuilder.bootstrap())

	var body: some Scene {
		WindowGroup {
			RootView(model: model)
		}
	}
}
