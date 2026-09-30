import EnduragentCoach
import Testing

@Suite struct WellnessFormattingTests {
	@Test(arguments: [
		(1e20, "100000000000000000000"), (Double.nan, "—"),
		(Double.infinity, "—"), (-Double.infinity, "—"), (42.6, "43"), (-42.6, "-43"),
	])
	func wellnessWholeNumbersAreSafe(value: Double, expected: String) {
		#expect(WellnessDay.wholeNumber(value) == expected)
	}

	@Test func missingWellnessUsesPlaceholder() {
		#expect(WellnessDay.wholeNumber(nil) == "—")
	}
}
