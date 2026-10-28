import Foundation

public struct PhoneRefusal: DescribedFailure {
	public let description: String
}

public struct PhoneSessionPlan: Sendable, Equatable, Decodable {
	public static let folder = "apps/ios/EnduragentPhoneTests/Sessions"

	public let name: String
	public let cap: Int
	public let ledger: String
	public let steps: [PhoneStep]

	public static func path(root: String, name: String) -> String {
		NodePath.join(root, folder, "\(name).json")
	}

	public static func load(path: String) throws -> PhoneSessionPlan {
		try JSONDecoder().decode(PhoneSessionPlan.self, from: FileSystem.read(path))
	}

	public func planned(_ steps: [String]) -> Int {
		self.steps.filter { steps.contains($0.id) }.reduce(0) { $0 + $1.planned }
	}

	public func plannedSteps(_ steps: [String]) -> [PlannedPhoneStep] {
		self.steps.filter { steps.contains($0.id) }.map {
			PlannedPhoneStep(id: $0.id, planned: $0.planned)
		}
	}

	public func quotedMessages(of steps: [String]) -> [String] {
		self.steps.filter { steps.contains($0.id) }.flatMap(\.checks).flatMap { check in
			[check.look, check.pass].flatMap { text in
				text.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
					.filter { !$0.offset.isMultiple(of: 2) }.map { String($0.element) }
			}
		}
	}
}

public struct PhoneStep: Sendable, Equatable, Decodable {
	public let id: String
	public let driver: PhoneDriver
	public let planned: Int
	public let setup: [String]
	public let checks: [PhoneCheck]
	public let endsWith: String
}

public struct PhoneCheck: Sendable, Equatable, Decodable {
	public let look: String
	public let pass: String
}

public enum PhoneDriver: Sendable, Equatable, Decodable {
	case operatorOnInstalledBuild
	case runnerOnInstalledBuild(test: RunnerTest)
	case installDebugBuild
	case runnerOnDebugBuild(test: RunnerTest)

	private enum Form: String, CodingKey {
		case operatorOnInstalledBuild, runnerOnInstalledBuild, installDebugBuild,
			runnerOnDebugBuild
	}

	public var build: PhoneBuild {
		switch self {
		case .operatorOnInstalledBuild, .runnerOnInstalledBuild: .testFlight
		case .installDebugBuild, .runnerOnDebugBuild: .debug
		}
	}

	public init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let name = try? container.decode(String.self) {
			switch Form(rawValue: name) {
			case .operatorOnInstalledBuild: self = .operatorOnInstalledBuild
			case .installDebugBuild: self = .installDebugBuild
			case .runnerOnInstalledBuild, .runnerOnDebugBuild, nil:
				throw DecodingError.dataCorruptedError(
					in: container, debugDescription: "\(name) is not a driver without a test")
			}
			return
		}
		let forms = try decoder.container(keyedBy: Form.self)
		guard forms.allKeys.count == 1, let form = forms.allKeys.first else {
			throw DecodingError.dataCorrupted(
				DecodingError.Context(
					codingPath: decoder.codingPath,
					debugDescription: "A runner driver names exactly one form"))
		}
		let test = try forms.decode(RunnerTest.self, forKey: form)
		switch form {
		case .runnerOnInstalledBuild: self = .runnerOnInstalledBuild(test: test)
		case .runnerOnDebugBuild: self = .runnerOnDebugBuild(test: test)
		case .operatorOnInstalledBuild, .installDebugBuild:
			throw DecodingError.dataCorruptedError(
				forKey: form, in: forms, debugDescription: "\(form.rawValue) runs no test")
		}
	}
}

public enum PhoneBuild: String, Sendable, Equatable {
	case testFlight, debug

	public var cloudKitEnvironment: String {
		switch self {
		case .testFlight: "Production"
		case .debug: "Development"
		}
	}
}

public struct RunnerTest: Sendable, Equatable, Decodable {
	public let scheme: String
	public let testClass: String
	public let testMethod: String
	public let actionsAttachment: String
}

public struct SittingOrder: Sendable, Equatable, Decodable {
	public static let file = "sitting.json"
	static let fill = SittingStep(session: "closeout", step: "closeout/fill")
	static let update = SittingStep(session: "closeout", step: "closeout/update")
	static let debugInstall = SittingStep(session: "closeout", step: "closeout/debug-install")
	static let twoPhone = SittingStep(session: "closeout", step: "closeout/two-phone")
	static let secondDeviceDiagnostics = SittingStep(
		session: "closeout", step: "closeout/second-device-diagnostics")

	public let steps: [SittingStep]

	public init(steps: [SittingStep]) {
		self.steps = steps
	}

	public static func load(root: String) throws -> SittingOrder {
		try JSONDecoder().decode(
			SittingOrder.self,
			from: FileSystem.read(NodePath.join(root, PhoneSessionPlan.folder, file)))
	}

	public static func problems(order: SittingOrder, sessions: [PhoneSessionPlan]) -> [String] {
		var problems: [String] = []
		var drivers: [SittingStep: PhoneDriver] = [:]
		for session in sessions {
			for step in session.steps {
				let listed = SittingStep(session: session.name, step: step.id)
				drivers[listed] = step.driver
				let count = order.steps.count { $0 == listed }
				if count == 0 { problems.append("\(step.id) is missing") }
				if count > 1 { problems.append("\(step.id) is listed \(count) times") }
			}
		}
		for step in order.steps where drivers[step] == nil {
			problems.append("\(step.session) has no step \(step.step)")
		}
		if order.steps.first != fill { problems.append("\(fill.step) is not first") }
		if order.steps.dropFirst().first != update {
			problems.append("\(update.step) is not second")
		}
		if let install = order.steps.firstIndex(of: debugInstall) {
			for step in order.steps[(install + 1)...] where drivers[step]?.build == .testFlight {
				problems.append("\(step.step) runs on TestFlight after \(debugInstall.step)")
			}
		}
		if let twoPhone = order.steps.firstIndex(of: twoPhone),
			let diagnostics = order.steps.firstIndex(of: secondDeviceDiagnostics),
			diagnostics < twoPhone
		{
			problems.append("\(secondDeviceDiagnostics.step) comes before \(Self.twoPhone.step)")
		}
		return problems
	}
}

public struct SittingStep: Sendable, Hashable, Decodable {
	public let session: String
	public let step: String

	public init(session: String, step: String) {
		self.session = session
		self.step = step
	}
}

public struct PhoneLedgerRow: Sendable, Equatable {
	public let steps: [String]
	public let budget: Int
	public let spent: Int
}

public enum PhoneBudget {
	public static func approve(
		_ answer: String, steps: [String], plan: PhoneSessionPlan, spent: Int
	) throws -> PhoneLedgerRow {
		guard let budget = wholeNumber(answer) else {
			throw PhoneRefusal(
				description: "No message budget approved. Stop before build, launch or Send.")
		}
		let planned = plan.planned(steps)
		let named = steps.joined(separator: ", ")
		guard budget >= planned else {
			throw PhoneRefusal(
				description:
					"A budget of \(budget) is below the \(planned) message actions \(named) plan. Stop before build, launch or Send."
			)
		}
		guard spent + budget <= plan.cap else {
			throw PhoneRefusal(
				description:
					"\(spent) message actions are spent, so a budget of \(budget) would pass the \(plan.name) cap of \(plan.cap). Stop before build, launch or Send."
			)
		}
		return PhoneLedgerRow(steps: steps, budget: budget, spent: budget)
	}

	static func wholeNumber(_ text: String) -> Int? {
		let digits = Array(text.utf8)
		guard !digits.isEmpty, digits.count <= 9,
			digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
			digits.count == 1 || digits[0] != UInt8(ascii: "0")
		else { return nil }
		return Int(text)
	}
}

public struct DiagnosticsScanInputs: Sendable, Equatable {
	public let athleteID: String
	public let intervalsKey: String
	public let fixedMessages: [String]

	public init(athleteID: String, intervalsKey: String, fixedMessages: [String]) {
		self.athleteID = athleteID
		self.intervalsKey = intervalsKey
		self.fixedMessages = fixedMessages
	}
}

public enum DiagnosticsFileScan {
	static let keys = [
		"access", "app", "device", "format", "journal", "language", "lines", "made", "records",
		"training",
	]
	static let secretShapes = [
		("sk-or-v1-", #"sk-or-v1-"#), ("sk-", #"\bsk-"#), ("Bearer ", #"Bearer "#),
		("ghp_", #"\bghp_"#),
	]
	static let athleteShape = #"\bi\d{4,10}\b"#

	public static func problems(in file: Data, inputs: DiagnosticsScanInputs) throws -> [String] {
		guard let text = String(data: file, encoding: .utf8) else {
			return ["The file is not UTF-8 text."]
		}
		let patterns = JavaScriptPatterns()
		var problems = try structure(of: text)
		for (name, shape) in secretShapes where try patterns.test(shape, text) {
			problems.append("The file holds the secret shape \(name).")
		}
		if !inputs.athleteID.isEmpty, text.contains(inputs.athleteID) {
			problems.append("The file holds the test account's athlete id.")
		}
		if try patterns.test(athleteShape, text) {
			problems.append("The file holds an athlete id shape.")
		}
		if !inputs.intervalsKey.isEmpty, text.contains(inputs.intervalsKey) {
			problems.append("The file holds the intervals key.")
		}
		for message in inputs.fixedMessages where !message.isEmpty && text.contains(message) {
			problems.append("The file holds the message \(message.quotedAsJSON).")
		}
		return problems
	}

	private static func structure(of text: String) throws -> [String] {
		let file: JSONValue
		do {
			file = try JSONValue.parse(text)
		} catch let failure as JSONSyntaxFailure {
			return ["The file is not JSON: \(failure.description)."]
		}
		guard case .object(let members) = file else { return ["The file is not a JSON object."] }
		var problems: [String] = []
		let found = members.map(\.key).sorted()
		if found != keys {
			problems.append(
				"The file's top-level keys are \(found.joined(separator: ", ")), not \(keys.joined(separator: ", "))."
			)
		}
		guard case .array(let lines) = try file.member("lines") else {
			return problems + ["The file has no list of lines."]
		}
		let usage = try lines.contains { line in
			guard case .object = line, case .object = try line.member("usage") else { return false }
			let usage = try line.member("usage")
			guard let model = try usage.member("model").string, !model.isEmpty else { return false }
			return try usage.member("inputTokens").number != nil
				&& usage.member("outputTokens").number != nil
		}
		if !usage { problems.append("The file has no usage line with a model and tokens.") }
		return problems
	}
}
