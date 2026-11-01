import Foundation

public struct PhoneSteps: Equatable, Sendable {
	public let ids: [String]

	public init(first: String, last: String, plan: PhoneSessionPlan) throws {
		let count = plan.steps.count
		guard let first = PhoneBudget.wholeNumber(first), let last = PhoneBudget.wholeNumber(last),
			first >= 1, first <= last, last <= count
		else {
			throw PhoneRefusal(
				description:
					"Name the first and last step, from 1 to \(count), first not after last.")
		}
		ids = plan.steps[(first - 1)...(last - 1)].map(\.id)
	}
}

public struct PhoneLedger: Equatable, Sendable {
	public static let header = "steps\tbudget\tspent"
	public static let messageActionLine = "Message action "

	public let rows: [PhoneLedgerRow]

	public var spent: Int { rows.map(\.spent).reduce(0, +) }

	public var text: String {
		([Self.header]
			+ rows.map {
				"\($0.steps.joined(separator: ","))\t\($0.budget)\t\($0.spent)"
			})
			.map { $0 + "\n" }.joined()
	}

	public init(text: String?, plan: PhoneSessionPlan) throws {
		guard let text else {
			rows = []
			return
		}
		var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		if lines.last?.isEmpty == true { lines.removeLast() }
		guard let header = lines.first, header.hasSameUnits(as: Self.header) else {
			throw PhoneRefusal(
				description:
					"messages.tsv does not start with its header. Stop before build, launch or Send."
			)
		}
		rows = try lines.dropFirst().enumerated().map { index, line in
			guard let row = Self.row(line, plan: plan) else {
				throw PhoneRefusal(
					description:
						"messages.tsv row \(index + 1) cannot be read: \(line). Stop before build, launch or Send."
				)
			}
			return row
		}
	}

	private init(rows: [PhoneLedgerRow]) {
		self.rows = rows
	}

	public func recording(_ booked: PhoneLedgerRow, actions: String?) -> PhoneLedger {
		let spent =
			actions.map { log in
				log.split(separator: "\n").count {
					String($0).hasUnitPrefix(Self.messageActionLine)
				}
			} ?? booked.budget
		return PhoneLedger(
			rows: rows + [PhoneLedgerRow(steps: booked.steps, budget: booked.budget, spent: spent)])
	}

	private static func row(_ line: String, plan: PhoneSessionPlan) -> PhoneLedgerRow? {
		let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
		guard fields.count == 3 else { return nil }
		let known = Set(plan.steps.map(\.id))
		let steps = fields[0].split(separator: ",", omittingEmptySubsequences: false).map(
			String.init)
		guard steps.allSatisfy(known.contains), let budget = PhoneBudget.wholeNumber(fields[1]),
			let spent = PhoneBudget.wholeNumber(fields[2]), budget <= plan.cap, spent <= budget
		else { return nil }
		return PhoneLedgerRow(steps: steps, budget: budget, spent: spent)
	}
}

public enum PlanPhoneBudget {
	public static func actionsFile(in manifest: JSONValue, named attachment: String) throws
		-> String?
	{
		var found: [String] = []
		for entry in try manifest.elements() {
			for item in try entry.member("attachments").elements() {
				guard let name = try item.member("suggestedHumanReadableName").string,
					isActionsAttachment(name, named: attachment),
					let file = try item.member("exportedFileName").string
				else { continue }
				found.append(file)
			}
		}
		return found.count == 1 ? found[0] : nil
	}

	private static func isActionsAttachment(_ name: String, named attachment: String) -> Bool {
		guard name.hasUnitPrefix(attachment), name.hasUnitSuffix(".txt") else {
			return false
		}
		let middle = name.slice(attachment.utf16.count, name.utf16.count - 4)
		guard !middle.isEmpty else { return true }
		let parts = middle.split(separator: "_", omittingEmptySubsequences: false)
		return parts.count == 3 && parts[0].isEmpty
			&& PhoneBudget.wholeNumber(String(parts[1])) != nil
			&& UUID(uuidString: String(parts[2])) != nil
	}
}
