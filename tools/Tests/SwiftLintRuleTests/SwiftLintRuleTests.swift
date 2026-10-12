import Foundation
import Testing
import ToolSupport

private final class BuiltProducts {}

struct SwiftLintRuleTests {
	@Test(.timeLimit(.minutes(1)), arguments: LintProbe.all)
	func flagsOnlyTheLinesTheRuleRejects(_ probe: LintProbe) throws {
		let repository = try Checkout.root(ofExecutable: Bundle(for: BuiltProducts.self).bundlePath)
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ios-swiftlint-check-\(UUID().uuidString)", isDirectory: true)
		let file = root.appendingPathComponent(probe.path)
		try FileManager.default.createDirectory(
			at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(probe.lines.map { "\($0.source)\n" }.joined().utf8).write(to: file)
		let linted = Result {
			try Subprocess().collect(
				"swiftlint",
				[
					"lint", "--config", "\(repository)/.swiftlint.yml", "--quiet", "--no-cache",
					"--reporter", "json", file.path,
				])
		}
		try FileManager.default.removeItem(at: root)
		let report = try linted.get()

		let violations = try JSONValue.parse(String(decoding: report.output, as: UTF8.self))
			.elements().filter { try $0.member("rule_id").isString(probe.rule) }
		let rejected = probe.lines.indices.filter { probe.lines[$0].rejected }.map {
			Double($0 + 1)
		}
		#expect(try violations.compactMap { try $0.member("line").number }.sorted() == rejected)
		#expect(
			probe.alwaysHoldsAViolation
				? report.end.status == 2 : [0, 2].contains(report.end.status),
			"\(String(decoding: report.errors, as: UTF8.self))")
	}
}

struct LintProbe: Sendable, CustomTestStringConvertible {
	let name: String
	let rule: String
	let path: String
	let lines: [(source: String, rejected: Bool)]
	let alwaysHoldsAViolation: Bool

	var testDescription: String { "\(name): \(path)" }

	private static let app = "apps/ios/Enduragent"
	private static let package = "apps/ios/Packages/EnduragentCoach"
	private static let optionalTry = "try" + "?"
	private static let catchAll = "cat" + "ch"

	static let all =
		starterPolicy + [swallowedError, optionalTryProbe] + sessionFactory + console + fixedColors

	private static let fixedColors = [
		("\(app)/Chat/Probe.swift", true),
		("\(app)/Settings/ProbeDebugView.swift", true),
		("apps/ios/EnduragentTests/Probe.swift", false),
		("apps/ios/EnduragentUITests/Probe.swift", false),
	].map { path, rejected in
		LintProbe(
			name: "no_fixed_colors rejects colors that ignore dark appearance in app code",
			rule: "no_fixed_colors", path: path,
			lines: [
				("let fill = Color(red: 0.1, green: 0.2, blue: 0.3)", rejected),
				("let fill = Color(white: 0.9)", rejected),
				("let fill = Color(.sRGB, red: 0.1, green: 0.2, blue: 0.3, opacity: 1)", rejected),
				("let fill = Color(hue: 0.5, saturation: 1, brightness: 1)", rejected),
				("let fill = Color(hex: 0x1A2B3C)", rejected),
				("let fill = Color(0x1A2B3C)", rejected),
				(##"let fill = Color("#1A2B3C")"##, rejected),
				("let fill = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)", rejected),
				("let fill = Color.white", rejected),
				("let fill = Color.black.opacity(0.5)", rejected),
				("row.foregroundStyle(.white)", rejected),
				("row.foregroundStyle( .black )", rejected),
				("row.foregroundColor(.white)", rejected),
				("row.background(.black)", rejected),
				("row.tint(.white)", rejected),
				("row.preferredColorScheme(.dark)", rejected),
				("row.foregroundStyle(.secondary)", false),
				("row.foregroundStyle(Color.primary)", false),
				("row.background(.background)", false),
				("row.background(.quaternary, in: shape)", false),
				("row.listRowBackground(Color.clear)", false),
				("let fill = Color(.systemBackground)", false),
				(#"let fill = Color("AccentColor")"#, false),
				("let fill = Color.accentColor", false),
			], alwaysHoldsAViolation: false)
	}

	private static let starterPolicy = [
		("\(app)/App/Probe.swift", true),
		("\(app)/Credits/ProbeDebugView.swift", true),
		("\(package)/Sources/EnduragentCoach/Probe.swift", false),
	].map { path, rejected in
		LintProbe(
			name: "starter_policy_in_package rejects direct grants in app code",
			rule: "starter_policy_in_package", path: path,
			lines: [
				("let outcome = try await coach.credits.grant(deviceCheck: token)", rejected),
				("let outcome = try await credits . grant ( deviceCheck : token)", rejected),
				("let notice = await coach.claimStarter(deviceCheck: token)", false),
			], alwaysHoldsAViolation: false)
	}

	private static let swallowedError = LintProbe(
		name: "swallowed_error rejects relabeling every failure as cancellation",
		rule: "swallowed_error", path: "Probe.swift",
		lines: [
			("do { try run() } \(catchAll) { throw CancellationError() }", true),
			("do { try run() } \(catchAll) let failure { throw CancellationError() }", true),
			(
				"do { try run() } \(catchAll) is CancellationError { throw CancellationError() }",
				false
			),
			("do { try run() } \(catchAll) { throw error }", false),
		], alwaysHoldsAViolation: true)

	private static let optionalTryProbe = LintProbe(
		name: "optional_try accepts only a standalone conditional container decode probe",
		rule: "optional_try", path: "Sources/EnduragentCoach/Testing/Probe.swift",
		lines: [
			("let value = \(optionalTry) load()", true),
			("let value = (\(optionalTry) load()) ?? []", true),
			("let value = (\(optionalTry) container.decode(Int.self)) ?? 0", true),
			("if let value = \(optionalTry) container.decode(Int.self) ?? 0 {", true),
			(
				"if let value = \(optionalTry) container.decode(Int.self) { let other = \(optionalTry) load() }",
				true
			),
			("if let value = \(optionalTry) container.decode(Bool.self) {", false),
			("if let value = \(optionalTry) container.decode([JSONValuePayload].self) {", false),
			(
				"if let value = \(optionalTry) container.decode([String: JSONValuePayload].self) {",
				false
			),
		], alwaysHoldsAViolation: true)

	private static let sessionFactory = [
		("\(app)/App/Probe.swift", true),
		("\(package)/Sources/EnduragentCoach/Probe.swift", true),
		("\(app)/App/Transport/HTTPSession.swift", true),
		("\(package)/Tests/EnduragentCoachTests/Probe.swift", false),
		("apps/ios/EnduragentTests/Probe.swift", false),
		("\(package)/Sources/EnduragentCoach/Transport/HTTPSession.swift", false),
	].map { path, rejected in
		LintProbe(
			name: "one_session_factory rejects every construction outside the package factory",
			rule: "one_session_factory", path: path,
			lines: [
				("let session = URLSession(configuration: config)", rejected),
				("let session = URLSession.init(configuration: config)", rejected),
				("let session: URLSession = .init(configuration: config)", rejected),
				("let session = URLSession.shared", rejected),
				("let session = URLSession . shared", rejected),
				("let client = Client(session: .shared)", rejected),
				("let configuration = URLSessionConfiguration.ephemeral", rejected),
				("let app = UIApplication.shared", false),
				("let scheduler = BGTaskScheduler.shared", false),
			], alwaysHoldsAViolation: false)
	}

	private static let console = [
		"Enduragent/App", "Packages/EnduragentCoach/Tests/EnduragentCoachTests", "EnduragentTests",
		"EnduragentUITests", "EnduragentPhoneTests",
	].map { target in
		LintProbe(
			name:
				"no_print rejects console output and accepts an explicit text stream in every Swift target",
			rule: "no_print", path: "apps/ios/\(target)/Probe.swift",
			lines: [
				(#"print("value")"#, true),
				(#"debugPrint("value")"#, true),
				(#"NSLog("value")"#, true),
				("dump(request)", true),
				(#"dump("value, to: text")"#, true),
				("dump(request, to: &text)", false),
				(#"dump(request, name: "value", to: &text)"#, false),
				("dump(makeRequest(), to: &text)", false),
			], alwaysHoldsAViolation: true)
	}
}
