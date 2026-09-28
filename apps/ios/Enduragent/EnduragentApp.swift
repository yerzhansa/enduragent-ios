import SwiftUI

@main
struct EnduragentApp: App {
	@State private var launch = AppLaunch.start()

	var body: some Scene {
		WindowGroup {
			switch launch {
			case .ready(let model):
				RootView(model: model)
			case .storageUnavailable(let phrasebook, let failure):
				StorageUnavailableView(phrasebook: phrasebook, failure: failure)
			}
		}
	}
}
