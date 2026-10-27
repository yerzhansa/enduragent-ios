import Testing
import ToolSupport

struct JavaScriptNumberTextTests {
	struct Printed: Sendable, CustomTestStringConvertible {
		let value: Double
		let text: String

		var testDescription: String { text }
	}

	@Test(arguments: [
		Printed(value: 1e21, text: "1e+21"),
		Printed(value: 1e-7, text: "1e-7"),
		Printed(value: 1e16, text: "10000000000000000"),
		Printed(value: -0.0, text: "0"),
		Printed(value: 9_007_199_254_740_994, text: "9007199254740994"),
	])
	func textIsJavaScriptsStringOfTheNumber(_ printed: Printed) {
		#expect(JavaScriptNumber.text(printed.value) == printed.text)
	}

	@Test func fixedToOneDecimalBreaksATieUpward() {
		#expect(JavaScriptNumber.fixedToOneDecimal(2.25) == "2.3")
	}
}
