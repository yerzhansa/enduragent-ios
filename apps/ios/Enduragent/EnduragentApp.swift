import SwiftUI

@main
struct EnduragentApp: App {
	@State private var launch: AppLaunch?

	var body: some Scene {
		WindowGroup {
			Group {
				switch launch {
				case .ready(let model):
					RootView(model: model)
				case .storageUnavailable(let phrasebook, let failure):
					StorageUnavailableView(displayLocale: phrasebook, failure: failure)
				case nil:
					ProgressView()
				}
			}
			.task {
				guard launch == nil else { return }
				launch = await AppLaunch.start()
			}
		}
	}
}
