import EnduragentCoach
import Testing

@testable import Enduragent

struct SlashListTests {
	@Test func planIsHiddenFromTheList() {
		#expect(VisibleSlash.commands == [.review, .status, .workout, .language])
	}
}
