import XCTest

extension TutorialHarness {
	static func readsEmpty(_ field: XCUIElement) -> Bool {
		guard let shown = field.value as? String else { return true }
		return shown.isEmpty || shown == field.placeholderValue
	}
}
