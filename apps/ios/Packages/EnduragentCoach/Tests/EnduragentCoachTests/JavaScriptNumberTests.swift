import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct JavaScriptNumberTests {
	struct Printed: Sendable, CustomTestStringConvertible {
		let value: Double
		let text: String

		var testDescription: String { text }
	}

	struct Rounded: Sendable, CustomTestStringConvertible {
		let value: Double
		let rounded: Double

		var testDescription: String { "\(value)" }
	}

	static let printed = [
		Printed(value: 1e21, text: "1e+21"),
		Printed(value: 1e-7, text: "1e-7"),
		Printed(value: 1e16, text: "10000000000000000"),
		Printed(value: -0.0, text: "0"),
		Printed(value: 9_007_199_254_740_994, text: "9007199254740994"),
	]

	@Test func everyNumberInTheFeasibilityPlanDraftAndHeadlineOutputsPrintsAsJavaScriptWroteIt()
		throws
	{
		let files = ["feasibility", "headline"] + (try PlanFixtures.planDraftFiles())
		var cases = 0
		var found = 0
		var compared = 0
		var misprinted: [String] = []
		for file in files {
			let tokens = try PlanFixtures.numberTokens(file)
			cases += tokens.count
			for token in tokens.joined() {
				found += 1
				guard let value = Double(token) else { continue }
				compared += 1
				let text = JavaScriptNumber.text(value)
				if text != token { misprinted.append("\(file): \(token) printed as \(text)") }
			}
		}
		#expect(misprinted.isEmpty)
		#expect(cases == (try PlanFixtures.manifestCount(files)))
		#expect(cases > 0)
		#expect(compared == found)
		#expect(compared > 0)
	}

	@Test(arguments: printed)
	func textIsJavaScriptsStringOfTheNumber(_ printed: Printed) {
		#expect(JavaScriptNumber.text(printed.value) == printed.text)
		#expect(JavaScriptNumber.json(printed.value) == printed.text)
	}

	@Test func fixedRoundsTheExactBinaryValueAndBreaksATieUpward() {
		#expect(JavaScriptNumber.fixed(2.25, digits: 1) == "2.3")
		#expect(JavaScriptNumber.fixed(1.005, digits: 2) == "1.00")
	}

	@Test(arguments: [
		Rounded(value: -2.5, rounded: -2), Rounded(value: 2.5, rounded: 3),
	])
	func roundBreaksATieTowardPositiveInfinity(_ rounding: Rounded) {
		#expect(JavaScriptNumber.round(rounding.value) == rounding.rounded)
	}

	@Test(arguments: [
		Rounded(value: 0.25, rounded: 0.3), Rounded(value: -0.25, rounded: -0.2),
	])
	func roundToTenthsBreaksATieTowardPositiveInfinity(_ rounding: Rounded) {
		#expect(JavaScriptNumber.roundToTenths(rounding.value) == rounding.rounded)
	}

	@Test(arguments: [Double.nan, .infinity, -.infinity])
	func jsonOfANonFiniteNumberIsNull(_ value: Double) {
		#expect(JavaScriptNumber.json(value) == "null")
	}

	@Test func canonicalTextPrintsNumbersAsJavaScript() {
		let numbers = JSONValue.array([
			.number(1e16), .number(1e-7), .number(-0.0), .number(9_007_199_254_740_994),
			.number(.nan), .number(87.5),
		])
		let compact = "[10000000000000000,1e-7,0,9007199254740994,null,87.5]"
		#expect(numbers.canonicalDigestInput() == compact)
		#expect(
			canonicalJSON(numbers)
				== "[\n  10000000000000000,\n  1e-7,\n  0,\n  9007199254740994,\n  null,\n  87.5\n]"
		)
	}
}
