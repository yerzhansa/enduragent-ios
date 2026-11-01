import Foundation
import Testing
import ToolSupport

struct PhoneSessionTests {
	static var repository: String {
		URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent().path
	}

	static func committed(_ name: String) throws -> PhoneSessionPlan {
		try PhoneSessionPlan.load(path: PhoneSessionPlan.path(root: repository, name: name))
	}

	static func sessions() throws -> [PhoneSessionPlan] {
		try ["m4", "plan", "closeout"].map(committed)
	}

	static func driver(_ json: String) throws -> PhoneDriver {
		try JSONDecoder().decode(PhoneDriver.self, from: Data(json.utf8))
	}

	@Test func theCommittedFilesPlanTheirTotalsUnderTheirCaps() throws {
		let sessions = try Self.sessions()
		#expect(sessions.map(\.name) == ["m4", "plan", "closeout"])
		#expect(sessions.map { $0.planned($0.steps.map(\.id)) } == [12, 12, 32])
		#expect(sessions.map(\.cap) == [40, 30, 50])
		#expect(
			sessions.map(\.ledger) == [
				"enduragent-m4/PHONE/messages.tsv", "enduragent-m5/PHONE/messages.tsv",
				"enduragent-m6/PHONE/messages.tsv",
			])
		#expect(
			try Self.committed("m4").steps.map(\.id) == [
				"m4/list", "m4/repeat-ride", "m4/mixed-request", "m4/approve-later",
				"m4/race-move", "m4/external-edit", "m4/edit-and-delete", "m4/offline-approve",
			])
		#expect(
			try Self.committed("m4").steps.map(\.planned) == [1, 1, 3, 0, 1, 1, 3, 2])
		#expect(
			try Self.committed("plan").steps.map(\.id) == (1...5).map { "plan/\($0)" } + ["plan/7"])
	}

	@Test func theCommittedSittingHasNoProblem() throws {
		let order = try SittingOrder.load(root: Self.repository)
		#expect(SittingOrder.problems(order: order, sessions: try Self.sessions()) == [])
		#expect(order.steps.count == 29)
	}

	@Test(arguments: [
		("a missing step", ["m4/list is missing"]),
		("a step listed twice", ["plan/3 is listed 2 times"]),
		("a step no session has", ["m4 has no step m4/upgrade"]),
		("fill not first", ["closeout/fill is not first", "closeout/update is not second"]),
		("update not second", ["closeout/update is not second"]),
		(
			"a TestFlight step after the Debug install",
			["closeout/about runs on TestFlight after closeout/debug-install"]
		),
		(
			"diagnostics on the second device before the two-phone step",
			["closeout/second-device-diagnostics comes before closeout/two-phone"]
		),
	])
	func aSittingThatBreaksARuleIsReported(_ sample: (String, [String])) throws {
		var steps = try SittingOrder.load(root: Self.repository).steps
		func index(_ step: String) throws -> Int {
			try #require(steps.firstIndex { $0.step == step })
		}
		switch sample.0 {
		case "a missing step":
			steps.remove(at: try index("m4/list"))
		case "a step listed twice":
			steps.insert(steps[try index("plan/3")], at: try index("plan/5"))
		case "a step no session has":
			steps.insert(SittingStep(session: "m4", step: "m4/upgrade"), at: 2)
		case "fill not first":
			steps.swapAt(0, 1)
		case "update not second":
			steps.swapAt(1, 2)
		case "a TestFlight step after the Debug install":
			let about = steps.remove(at: try index("closeout/about"))
			steps.insert(about, at: try index("closeout/debug-install") + 1)
		default:
			steps.swapAt(
				try index("closeout/two-phone"), try index("closeout/second-device-diagnostics"))
		}
		let problems = SittingOrder.problems(
			order: SittingOrder(steps: steps), sessions: try Self.sessions())
		#expect(problems == sample.1, "\(sample.0)")
	}

	@Test func eachDriverFormDecodesWithItsBuild() throws {
		let test =
			#"{"scheme": "EnduragentPhone", "testClass": "PlanPhoneRun", "testMethod": "testPlanPhoneRun", "actionsAttachment": "plan-phone-actions"}"#
		let installed = try Self.driver(#""operatorOnInstalledBuild""#)
		let runner = try Self.driver(#"{"runnerOnInstalledBuild": \#(test)}"#)
		let debug = try Self.driver(#""installDebugBuild""#)
		let debugRunner = try Self.driver(#"{"runnerOnDebugBuild": \#(test)}"#)
		#expect(installed == .operatorOnInstalledBuild)
		#expect(debug == .installDebugBuild)
		guard case .runnerOnInstalledBuild(let named) = runner,
			case .runnerOnDebugBuild(let debugNamed) = debugRunner
		else {
			Issue.record("a runner driver did not decode as a runner: \(runner), \(debugRunner)")
			return
		}
		#expect(named == debugNamed)
		#expect(named.scheme == "EnduragentPhone")
		#expect(named.testClass == "PlanPhoneRun")
		#expect(named.testMethod == "testPlanPhoneRun")
		#expect(named.actionsAttachment == "plan-phone-actions")
		#expect(
			[installed, runner, debug, debugRunner].map(\.build) == [
				.testFlight, .testFlight, .debug, .debug,
			])
		#expect(PhoneBuild.testFlight.cloudKitEnvironment == "Production")
		#expect(PhoneBuild.debug.cloudKitEnvironment == "Development")
	}

	@Test(arguments: [
		#""runnerOnInstalledBuild""#, #""operatorOnPhone""#,
		#"{"operatorOnInstalledBuild": {"scheme": "S", "testClass": "C", "testMethod": "m", "actionsAttachment": "a"}}"#,
		#"{"runnerOnDebugBuild": {"scheme": "S", "testClass": "C", "testMethod": "m"}}"#,
		#"{"runnerOnInstalledBuild": {"scheme": "S", "testClass": "C", "testMethod": "m", "actionsAttachment": "a"}, "runnerOnDebugBuild": {"scheme": "S", "testClass": "C", "testMethod": "m", "actionsAttachment": "a"}}"#,
	])
	func aDriverOutsideTheFourFormsIsRefused(_ json: String) {
		#expect(throws: DecodingError.self) { try Self.driver(json) }
	}

	@Test func everyCommittedRunnerStepNamesItsTest() throws {
		var runners = 0
		for step in try Self.sessions().flatMap(\.steps) {
			switch step.driver {
			case .runnerOnInstalledBuild(let test), .runnerOnDebugBuild(let test):
				runners += 1
				let names = [test.scheme, test.testClass, test.testMethod, test.actionsAttachment]
				#expect(names.allSatisfy { !$0.isEmpty }, "\(step.id)")
				#expect(test.testMethod.hasPrefix("test"), "\(step.id)")
			case .operatorOnInstalledBuild, .installDebugBuild:
				break
			}
		}
		#expect(runners == 13)
	}

	@Test func everyStepHasDecidableChecks() throws {
		for step in try Self.sessions().flatMap(\.steps) {
			#expect(
				step.checks.contains {
					!$0.pass.trimmingCharacters(in: .whitespaces).isEmpty
						&& !$0.look.trimmingCharacters(in: .whitespaces).isEmpty
				}, "\(step.id) has no check with a place to look and a value that passes")
			#expect(
				!step.endsWith.trimmingCharacters(in: .whitespaces).isEmpty,
				"\(step.id) says no state it ends with")
		}
	}

	@Test(arguments: [
		"", "plan/1", "plan/1=", "=2", "plan/1=two", "plan/1=02", "plan/1=-1", "plan/1=2,",
	])
	func aStepsVariableThatCannotBeReadPlansNothing(_ text: String) {
		#expect(PlannedPhoneStep.steps(in: text) == nil)
	}

	static let place = PhoneRunPlace(
		device: "DEVICE", folder: "/evidence", build: "/tests", appBuild: "/app",
		settings: ["ENDURAGENT_DEVICE_UPDATE_CHECK": "updated-together: 3"])

	static func start(
		_ session: String, _ steps: [String], answer: String, spent: Int = 0,
		built: inout Int
	) throws -> PhoneInvocation {
		var count = built
		defer { built = count }
		return try PhoneInvocationPlan.start(
			session: session, answer: answer, steps: steps, sessions: try sessions(),
			ledgerSpent: { _ in spent }, place: place,
			subprocess: {
				count += 1
				return Subprocess(directory: "/")
			}
		).invocation
	}

	@Test func eachCommandBooksItsOwnLedger() throws {
		var built = 0
		let booked = try [
			Self.start("m4", ["m4/list"], answer: "1", built: &built),
			Self.start("plan", ["plan/1"], answer: "2", built: &built),
			Self.start("closeout", ["closeout/about"], answer: "0", built: &built),
		]
		#expect(built == 3)
		#expect(
			booked.map(\.ledger) == [
				"enduragent-m4/PHONE/messages.tsv", "enduragent-m5/PHONE/messages.tsv",
				"enduragent-m6/PHONE/messages.tsv",
			])
		#expect(booked.map(\.cap) == [40, 30, 50])
		#expect(booked.map(\.budget) == [1, 2, 0])
		#expect(booked[0].commands == [])
		#expect(throws: PhoneRefusal.self) {
			try Self.start("closeout", ["closeout/fill"], answer: "four", built: &built)
		}
		#expect(throws: PhoneRefusal.self) {
			try Self.start("closeout", ["closeout/fill"], answer: "4", spent: 47, built: &built)
		}
		#expect(built == 3)
	}

	@Test(arguments: [
		(
			"closeout/keychain-proof",
			"TrainingKeychainDeviceProof/testSettingsCredentialSurvivesRelaunch"
		),
		("closeout/two-phone", "TwoPhoneReconnectCheck/testTwoPhoneReconnectStep"),
	])
	func aProofStepBuildsAndInstallsTheProofAppBeforeItsTest(_ sample: (String, String)) throws {
		var built = 0
		let commands = try Self.start("closeout", [sample.0], answer: "0", built: &built).commands
		#expect(commands.count == 3)
		#expect(
			commands.first?.prefix(6) == [
				"xcodebuild", "build", "-project", "apps/ios/Enduragent.xcodeproj", "-scheme",
				"EnduragentKeychainProof",
			])
		#expect(
			commands.dropFirst().first == [
				"xcrun", "devicectl", "device", "install", "app", "--device", "DEVICE",
				"/app/Build/Products/DebugKeychainProof-iphoneos/Enduragent.app",
			])
		let test = try #require(commands.last)
		#expect(test.prefix(2) == ["xcodebuild", "test"])
		#expect(test.contains("ENDURAGENT_PHONE_MESSAGE_BUDGET=0"))
		#expect(test.contains("ENDURAGENT_DEVICE_UPDATE_CHECK=updated-together: 3"))
		#expect(test.contains("-only-testing:EnduragentPhoneTests/\(sample.1)"))
	}

	@Test func runnerStepsOfOneTestShareOneRunThatPlansEachStep() throws {
		var built = 0
		let invocation = try Self.start(
			"closeout", ["closeout/feedback", "closeout/language"], answer: "4", built: &built)
		#expect(invocation.commands.count == 1)
		let command = try #require(invocation.commands.first)
		#expect(
			command.contains(
				"-only-testing:EnduragentPhoneTests/CloseoutPhoneRun/testCloseoutPhoneRun"))
		#expect(command.contains("ENDURAGENT_PHONE_MESSAGE_BUDGET=4"))
		#expect(
			command.contains("ENDURAGENT_PLAN_PHONE_STEPS=closeout/feedback=0,closeout/language=4"))
	}
}
