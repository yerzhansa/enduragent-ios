#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct FixtureModelCatalogDebugView: View {
		var model: ShellModel

		var body: some View {
			if model.services.fixture != nil, let choices = model.modelChoices {
				Text(state(choices.catalog.cache))
					.accessibilityIdentifier("fixture.catalogState")
			}
		}

		private func state(_ cache: CatalogCacheState) -> String {
			switch cache {
			case .available(let origin): "\(origin) available"
			case .refreshing(let origin): "\(origin) refreshing"
			case .retained(let origin, let issue): "\(origin) retained \(issue)"
			}
		}
	}
#endif
