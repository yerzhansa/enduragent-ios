import Foundation
import Testing

@testable import EnduragentCoach

struct ReviewNoticeMappingTests {
	@Test func aReviewBlockedBeforeTheUpgradeAsksForTheCoachAgain() throws {
		let notice = try #require(AthleteNotices.notice(for: .blocked(.reviewedBeforeUpgrade)))
		#expect(notice.key.rawValue == "workouts.blocked.reviewedBeforeUpgrade")
		#expect(notice.actions.isEmpty)
		#expect(
			CatalogPhrasebook(tag: .en).say(notice.key)
				== "This workout was reviewed before the app was updated. Ask the coach again.")
	}
}
