import Foundation

public struct PhoneRunPlace: Sendable, Equatable {
	public let device: String
	public let folder: String
	public let build: String
	public let appBuild: String
	public let settings: [String: String]

	public init(
		device: String, folder: String, build: String, appBuild: String,
		settings: [String: String]
	) {
		self.device = device
		self.folder = folder
		self.build = build
		self.appBuild = appBuild
		self.settings = settings
	}

	public var strayApp: String {
		NodePath.join(build, "Build/Products/Debug-iphoneos/Enduragent.app")
	}

	var proofApp: String {
		NodePath.join(appBuild, "Build/Products/DebugKeychainProof-iphoneos/Enduragent.app")
	}
}

public enum PhoneStageWork: Sendable, Equatable {
	case operatorTaps
	case ownCommand(String)
	case runs(test: RunnerTest, bundle: String, commands: [[String]])
}

public struct PhoneStage: Sendable, Equatable {
	public let steps: [String]
	public let work: PhoneStageWork
}

public struct PhoneInvocation: Sendable, Equatable {
	public let steps: [String]
	public let budget: Int
	public let spent: Int
	public let ledger: String
	public let cap: Int
	public let stages: [PhoneStage]

	public var commands: [[String]] {
		stages.flatMap { stage -> [[String]] in
			guard case .runs(_, _, let commands) = stage.work else { return [] }
			return commands
		}
	}

	public var row: PhoneLedgerRow { PhoneLedgerRow(steps: steps, budget: budget, spent: spent) }
}

public enum PhoneInvocationPlan {
	static let project = "apps/ios/Enduragent.xcodeproj"
	public static let proofScheme = "EnduragentKeychainProof"
	static let ownCommands = [
		"ChoicesInConversationCheck": "phone-check choices",
		"OpenRouterRecoveryPhoneCheck": "phone-check openrouter recover",
	]

	private enum Group {
		case operatorTaps([PhoneStep])
		case ownCommand(String, [PhoneStep])
		case stepsVariable(RunnerTest, [PhoneStep])
		case proofApp(RunnerTest, [PhoneStep])

		var steps: [PhoneStep] {
			switch self {
			case .operatorTaps(let steps), .ownCommand(_, let steps),
				.stepsVariable(_, let steps), .proofApp(_, let steps):
				steps
			}
		}
	}

	public static func start(
		session: String, answer: String, steps: [String], sessions: [PhoneSessionPlan],
		ledgerSpent: (PhoneSessionPlan) throws -> Int, place: PhoneRunPlace,
		subprocess: () -> Subprocess
	) throws -> (invocation: PhoneInvocation, subprocess: Subprocess) {
		let invocation = try make(
			session: session, answer: answer, steps: steps, sessions: sessions,
			ledgerSpent: ledgerSpent, place: place)
		return (invocation, subprocess())
	}

	public static func make(
		session: String, answer: String, steps: [String], sessions: [PhoneSessionPlan],
		ledgerSpent: (PhoneSessionPlan) throws -> Int, place: PhoneRunPlace
	) throws -> PhoneInvocation {
		guard let plan = sessions.first(where: { $0.name == session }) else {
			throw PhoneRefusal(description: "There is no \(session) session.")
		}
		let chosen = plan.steps.filter { steps.contains($0.id) }
		guard chosen.map(\.id) == steps else {
			throw PhoneRefusal(
				description:
					"\(steps.joined(separator: ", ")) are not steps of the \(session) session in its order."
			)
		}
		let row = try PhoneBudget.approve(
			answer, steps: steps, plan: plan, spent: try ledgerSpent(plan))
		return PhoneInvocation(
			steps: row.steps, budget: row.budget, spent: row.spent, ledger: plan.ledger,
			cap: plan.cap, stages: group(chosen).map { stage($0, budget: row.budget, place: place) }
		)
	}

	private static func group(_ steps: [PhoneStep]) -> [Group] {
		var groups: [Group] = []
		for step in steps {
			switch step.driver {
			case .operatorOnInstalledBuild, .installDebugBuild:
				groups.append(.operatorTaps([step]))
			case .runnerOnInstalledBuild(let test), .runnerOnDebugBuild(let test):
				if test.scheme == proofScheme {
					groups.append(.proofApp(test, [step]))
				} else if let own = ownCommands[test.testClass] {
					groups.append(.ownCommand(own, [step]))
				} else if case .stepsVariable(let previous, let earlier)? = groups.last,
					previous == test
				{
					groups[groups.count - 1] = .stepsVariable(test, earlier + [step])
				} else {
					groups.append(.stepsVariable(test, [step]))
				}
			}
		}
		return groups
	}

	private static func stage(_ group: Group, budget: Int, place: PhoneRunPlace) -> PhoneStage {
		let steps = group.steps
		let ids = steps.map(\.id)
		let bundle = NodePath.join(
			place.folder,
			(ids.first ?? "phone").replacingOccurrences(of: "/", with: "-") + ".xcresult")
		let allowed = steps.contains { $0.planned > 0 } ? budget : 0
		switch group {
		case .operatorTaps:
			return PhoneStage(steps: ids, work: .operatorTaps)
		case .ownCommand(let command, _):
			return PhoneStage(steps: ids, work: .ownCommand(command))
		case .stepsVariable(let test, _):
			let planned = PlannedPhoneStep.text(
				steps.map { PlannedPhoneStep(id: $0.id, planned: $0.planned) })
			let command =
				testCommand(
					test, configuration: "Debug", budget: allowed, bundle: bundle, place: place)
				+ ["\(PlannedPhoneStep.variable)=\(planned)"]
			return PhoneStage(
				steps: ids, work: .runs(test: test, bundle: bundle, commands: [command]))
		case .proofApp(let test, _):
			let configuration = "DebugKeychainProof"
			let build = [
				"xcodebuild", "build", "-project", project, "-scheme", test.scheme,
				"-configuration", configuration, "-sdk", "iphoneos", "-destination",
				"platform=iOS,id=\(place.device)", "-derivedDataPath", place.appBuild,
			]
			let install = [
				"xcrun", "devicectl", "device", "install", "app", "--device", place.device,
				place.proofApp,
			]
			let run =
				testCommand(
					test, configuration: configuration, budget: allowed, bundle: bundle,
					place: place)
				+ place.settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
			return PhoneStage(
				steps: ids,
				work: .runs(test: test, bundle: bundle, commands: [build, install, run]))
		}
	}

	private static func testCommand(
		_ test: RunnerTest, configuration: String, budget: Int, bundle: String,
		place: PhoneRunPlace
	) -> [String] {
		[
			"xcodebuild", "test", "-project", project, "-scheme", test.scheme, "-configuration",
			configuration, "-sdk", "iphoneos", "-destination", "platform=iOS,id=\(place.device)",
			"-derivedDataPath", place.build, "-parallel-testing-enabled", "NO",
			"-resultBundlePath", bundle,
			"-only-testing:EnduragentPhoneTests/\(test.testClass)/\(test.testMethod)",
			"ENDURAGENT_PHONE_MESSAGE_BUDGET=\(budget)",
		]
	}
}
