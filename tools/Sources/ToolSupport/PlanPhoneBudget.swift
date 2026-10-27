import Foundation

public struct PlanPhoneRefusal: DescribedFailure {
	public let description: String
}

public struct PlanPhoneSteps: Equatable, Sendable {
	public let first: Int
	public let last: Int

	public var planned: Int {
		PlanPhoneBudget.plannedActions[(first - 1)...(last - 1)].reduce(0, +)
	}

	public var text: String { "\(first)-\(last)" }

	public init(first: String, last: String) throws {
		guard let steps = Self(bounds: first, last) else {
			throw PlanPhoneRefusal(
				description:
					"Name the first and last step, from 1 to \(PlanPhoneBudget.plannedActions.count), first not after last."
			)
		}
		let largest = PlanPhoneBudget.largestTextStep
		guard steps.first == steps.last || !(steps.first...steps.last).contains(largest) else {
			throw PlanPhoneRefusal(
				description:
					"Step \(largest) runs alone: it needs the largest text size and VoiceOver, and the other steps need them off."
			)
		}
		self = steps
	}

	init?(text: String) {
		let bounds = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
		guard bounds.count == 2 else { return nil }
		self.init(bounds: bounds[0], bounds[1])
	}

	private init?(bounds first: String, _ last: String) {
		guard let first = PlanPhoneBudget.wholeNumber(first),
			let last = PlanPhoneBudget.wholeNumber(last), first >= 1, first <= last,
			last <= PlanPhoneBudget.plannedActions.count
		else { return nil }
		self.first = first
		self.last = last
	}
}

public struct PlanPhoneInvocation: Equatable, Sendable {
	public let steps: PlanPhoneSteps
	public let budget: Int
	public let spent: Int
}

public struct PlanPhoneLedger: Equatable, Sendable {
	public static let header = "steps\tbudget\tspent"

	public let invocations: [PlanPhoneInvocation]

	public var spent: Int { invocations.map(\.spent).reduce(0, +) }

	public var text: String {
		([Self.header] + invocations.map { "\($0.steps.text)\t\($0.budget)\t\($0.spent)" })
			.map { $0 + "\n" }.joined()
	}

	public init(text: String?) throws {
		guard let text else {
			invocations = []
			return
		}
		var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		if lines.last?.isEmpty == true { lines.removeLast() }
		guard let header = lines.first, header.hasSameUnits(as: Self.header) else {
			throw PlanPhoneRefusal(
				description:
					"messages.tsv does not start with its header. Stop before build, launch or Send."
			)
		}
		invocations = try lines.dropFirst().enumerated().map { index, line in
			guard let invocation = Self.invocation(line) else {
				throw PlanPhoneRefusal(
					description:
						"messages.tsv row \(index + 1) cannot be read: \(line). Stop before build, launch or Send."
				)
			}
			return invocation
		}
	}

	private init(invocations: [PlanPhoneInvocation]) {
		self.invocations = invocations
	}

	public func recording(_ invocation: PlanPhoneInvocation, actions: String?) -> PlanPhoneLedger {
		let spent =
			actions.map { log in
				log.split(separator: "\n").count {
					String($0).hasUnitPrefix(PlanPhoneBudget.messageActionLine)
				}
			} ?? invocation.budget
		return PlanPhoneLedger(
			invocations: invocations + [
				PlanPhoneInvocation(
					steps: invocation.steps, budget: invocation.budget, spent: spent)
			])
	}

	private static func invocation(_ line: String) -> PlanPhoneInvocation? {
		let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
		guard fields.count == 3, let steps = PlanPhoneSteps(text: fields[0]),
			let budget = PlanPhoneBudget.wholeNumber(fields[1]),
			let spent = PlanPhoneBudget.wholeNumber(fields[2]), budget <= PlanPhoneBudget.cap,
			spent <= budget
		else { return nil }
		return PlanPhoneInvocation(steps: steps, budget: budget, spent: spent)
	}
}

public enum PlanPhoneBudget {
	public static let cap = 30
	public static let plannedActions = [2, 1, 2, 2, 3, 1, 2]
	public static let largestTextStep = 6
	public static let actionsAttachment = "plan-phone-actions"
	public static let messageActionLine = "Message action "

	public static func approve(
		_ answer: String, for steps: PlanPhoneSteps, after ledger: PlanPhoneLedger
	) throws -> PlanPhoneInvocation {
		guard let budget = wholeNumber(answer), budget > 0 else {
			throw PlanPhoneRefusal(
				description: "No message budget approved. Stop before build, launch or Send.")
		}
		guard budget >= steps.planned else {
			throw PlanPhoneRefusal(
				description:
					"A budget of \(budget) is below the \(steps.planned) message actions steps \(steps.text) plan. Stop before build, launch or Send."
			)
		}
		guard ledger.spent + budget <= cap else {
			throw PlanPhoneRefusal(
				description:
					"\(ledger.spent) message actions are spent, so a budget of \(budget) would pass the milestone's \(cap). Stop before build, launch or Send."
			)
		}
		return PlanPhoneInvocation(steps: steps, budget: budget, spent: budget)
	}

	public static func actionsFile(in manifest: JSONValue) throws -> String? {
		var found: [String] = []
		for entry in try manifest.elements() {
			for item in try entry.member("attachments").elements() {
				guard let name = try item.member("suggestedHumanReadableName").string,
					isActionsAttachment(name),
					let file = try item.member("exportedFileName").string
				else { continue }
				found.append(file)
			}
		}
		return found.count == 1 ? found[0] : nil
	}

	private static func isActionsAttachment(_ name: String) -> Bool {
		guard name.hasUnitPrefix(actionsAttachment), name.hasUnitSuffix(".txt") else {
			return false
		}
		let middle = name.slice(actionsAttachment.utf16.count, name.utf16.count - 4)
		guard !middle.isEmpty else { return true }
		let parts = middle.split(separator: "_", omittingEmptySubsequences: false)
		return parts.count == 3 && parts[0].isEmpty && wholeNumber(String(parts[1])) != nil
			&& UUID(uuidString: String(parts[2])) != nil
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
