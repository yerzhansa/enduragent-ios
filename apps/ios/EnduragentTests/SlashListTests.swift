import EnduragentCoach
import Testing

@testable import Enduragent

struct SlashListTests {
	@Test func startIsListedWithItsMenuTitleAndPlanIsGone() {
		let phrasebook = CatalogPhrasebook(tag: .en, locale: "en")
		let rows = SlashCommand.allCases.map { ($0.rawValue, phrasebook.say($0.menuTitle, [:])) }
		#expect(rows.map(\.0) == ["/start", "/workout", "/status", "/review", "/language"])
		#expect(rows.first?.1 == "Start a fresh session")
		#expect(!rows.map(\.0).contains("/plan"))
		#expect(rows.allSatisfy { !$0.1.isEmpty })
	}
}
