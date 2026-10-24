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

	@Test(arguments: [
		Rounded(value: 13.1, rounded: 13.1), Rounded(value: 7.46, rounded: 7.5),
		Rounded(value: -6.47, rounded: -6.5),
	])
	func roundToTenthsRoundsToTheNearestTenth(_ rounding: Rounded) {
		#expect(JavaScriptNumber.roundToTenths(rounding.value) == rounding.rounded)
	}

	@Test(arguments: [Double.nan, .infinity, -.infinity])
	func jsonOfANonFiniteNumberIsNull(_ value: Double) {
		#expect(JavaScriptNumber.json(value) == "null")
	}

	@Test func everyFiniteNumberThePrinterWritesIsParsedBackBitForBit() throws {
		var generator = SplitMix64(state: 0x2_2D16_1755)
		var numbers: [Double] = [
			1.2345678901234568e-05, 1.2345678901234568e+20, 0.051853768363630676,
			0.00010000000000000002, 0.062499999999999993, 0, 1, -1, 600, 87.5,
		]
		for _ in 0..<20_000 {
			let bits = Double(bitPattern: generator.next())
			if bits.isFinite, bits != 0 { numbers.append(bits) }
			numbers.append(generator.logUniform(from: 1e-9, to: 1e-4))
			numbers.append(-generator.logUniform(from: 0x1p53, to: 1e21))
			numbers.append(generator.logUniform(from: 1e-4, to: 0x1p53))
		}
		for edge in [1e-9, 1e-4, 0x1p53, 1e21] {
			var above = edge
			var below = edge
			for _ in 0..<500 {
				numbers += [above, below.nextDown]
				above = above.nextUp
				below = below.nextDown
			}
		}

		let printed = JSONValue.array(numbers.map(JSONValue.number)).canonicalDigestInput()
		let parsed = try #require(try JSONValue.parse(printed).arrayValue)

		#expect(parsed.count == numbers.count)
		#expect(numbers.count > 80_000)
		let misread = zip(numbers, parsed).filter { number, value in
			value.numberValue?.bitPattern != number.bitPattern
		}
		#expect(misread.isEmpty, "\(misread.prefix(5).map { JavaScriptNumber.text($0.0) })")
	}

	@Test func everyStringThePrinterWritesIsParsedBackWhole() throws {
		let strings = [
			"\u{FEFF}Easy spin", "tab\t quote\" slash\\ nul\u{0} unit\u{1F}", "\u{2028}\u{2029}",
			"Zone 2 \u{1F6B4}", "",
		]

		let printed = JSONValue.array(strings.map(JSONValue.string)).canonicalDigestInput()
		let parsed = try #require(try JSONValue.parse(printed).arrayValue)

		#expect(
			parsed.map { $0.stringValue.map { Array($0.unicodeScalars) } }
				== strings.map { Array($0.unicodeScalars) })
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

private struct SplitMix64 {
	var state: UInt64

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var mixed = state
		mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
		mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
		return mixed ^ (mixed >> 31)
	}

	mutating func logUniform(from low: Double, to high: Double) -> Double {
		let fraction = Double(next() >> 11) * 0x1p-53
		let value = pow(10, log10(low) + (log10(high) - log10(low)) * fraction)
		return min(max(value, low), high.nextDown)
	}
}
