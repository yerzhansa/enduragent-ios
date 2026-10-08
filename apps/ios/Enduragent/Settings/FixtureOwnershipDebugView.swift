#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import SwiftUI

	struct FixtureOwnershipDebugView: View {
		let fixture: FixtureServices
		let account: TrainingAccount
		@State private var result = "waiting"

		var body: some View {
			Button("Seed earlier athlete information") {
				Task {
					do {
						try await AthleteOwnershipFixture.seed(
							in: fixture.records, account: account)
						result = "seeded"
					} catch {
						result = String(describing: error)
					}
				}
			}
			.accessibilityIdentifier("fixture.seedOwnership")
			Text(result)
				.accessibilityIdentifier("fixture.ownershipSeedResult")
		}
	}
#endif
