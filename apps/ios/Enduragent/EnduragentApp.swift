import SwiftUI

@main
struct EnduragentApp: App {
	@State private var launch: AppLaunch?
	@State private var launches = 0

	var body: some Scene {
		WindowGroup {
			Group {
				switch launch {
				case .ready(let model):
					RootView(model: model)
						.onChange(of: model.yourData.relaunchRequested) { _, requested in
							guard requested else { return }
							launch = nil
							launches += 1
						}
				case .storageUnavailable(let phrasebook, let failure):
					StorageUnavailableView(displayLocale: phrasebook, failure: failure)
				case nil:
					ProgressView()
				}
			}
			.task(id: launches) {
				guard launch == nil else { return }
				launch = await AppLaunch.start(afterErasure: launches > 0)
			}
		}
	}
}
