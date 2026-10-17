import Foundation

@testable import EnduragentCoach

enum LiveReviewVerdict {
	static let prepare = ToolName.prepareWorkoutChanges.rawValue
	static let pending = ToolName.getPendingWorkoutChanges.rawValue

	static func check(
		_ expectation: LiveReviewExpectation, on turn: LiveTurnRecord,
		calls: [LiveVerdict.ParsedCall]
	) -> String? {
		let preparations = calls.filter { $0.name == prepare }
		let before = turn.reviewBefore
		let after = turn.reviewAfter
		switch expectation {
		case .preparesNothing:
			return preparations.isEmpty ? nil : "workout changes were prepared"
		case .leavesNoReview:
			return turn.reviewPending || after != nil ? "a workout review is waiting" : nil
		case .preparesOnce(let kind):
			let results = turn.toolResults
			let kinds = preparations.filter { drafted(results[$0.id]) }
				.map { preparation(of: $0)["kind"]?.stringValue ?? "none" }
			return kinds == [kind.rawValue]
				? nil
				: "\(prepare) drafted a review with kinds [\(kinds.joined(separator: ", "))], not once with kind \(kind.rawValue)"
		case .readsPendingBeforePreparing:
			guard let first = calls.firstIndex(where: { $0.name == prepare }) else {
				return "\(prepare) was not called"
			}
			return calls[..<first].contains { $0.name == pending }
				? nil : "\(pending) was not called before \(prepare)"
		case .holds(let revision, let changes):
			guard let after else { return "no workout review waits" }
			let shapes = LiveChangeShape.shapes(of: after)
			guard after.revision.rawValue == revision, shapes == changes.sorted(),
				after.allowedControls == .approveOrCancel
			else {
				return
					"the review is at revision \(after.revision.rawValue) with \(shown(shapes)), not waiting for approval at revision \(revision) with \(shown(changes.sorted()))"
			}
			return nil
		case .revisesOnly(let shape):
			guard let before, let after, after.id == before.id else {
				return "the turn did not revise the waiting review"
			}
			let dropped = before.work.remaining.filter { !after.work.remaining.contains($0) }
			let added = after.work.remaining.filter { !before.work.remaining.contains($0) }
			let from = dropped.map { LiveChangeShape($0.action) }.sorted()
			let into = added.map { LiveChangeShape($0.action) }.sorted()
			return from == [shape] && into == [shape]
				? nil
				: "the revision changed \(shown(from)) into \(shown(into)), not only the \(shape)"
		case .replacesWith(let changes):
			guard let before, let after, after.id == before.id else {
				return "the turn did not replace the waiting review"
			}
			let bases = preparations.map { call -> String in
				let base = preparation(of: call)["base"]?.objectFields ?? [:]
				return
					"\(base["setId"]?.stringValue ?? "none")#\(base["revision"]?.numberValue.map { Int($0) } ?? 0)"
			}
			let expected = "\(before.id.ulid.rawValue)#\(before.revision.rawValue)"
			if bases != [expected] {
				return
					"the replacement named base [\(bases.joined(separator: ", "))], not \(expected)"
			}
			let earlier = Set(before.work.remaining.map(\.id))
			if after.work.remaining.contains(where: { earlier.contains($0.id) }) {
				return "the replacement kept a change of revision \(before.revision.rawValue)"
			}
			let shapes = LiveChangeShape.shapes(of: after)
			return shapes == changes.sorted()
				? nil : "the replacement holds \(shown(shapes)), not \(shown(changes.sorted()))"
		case .unchanged:
			guard let before else { return "no workout review waited before the turn" }
			return after == before ? nil : "the waiting review changed"
		case .endsUnprepared(let expected):
			let results = turn.toolResults
			return preparations.contains { call in expected.contains { results[call.id] == $0 } }
				? nil
				: "no \(prepare) result carried \(expected.joined(separator: " or "))"
		case .showsNotPrepared:
			return turn.notice == Catalog.workoutsNotPrepared
				? nil
				: "the turn shows \(turn.notice?.rawValue ?? "no review notice"), not \(Catalog.workoutsNotPrepared.rawValue)"
		}
	}

	private static func drafted(_ result: String?) -> Bool {
		guard let result,
			case .success(let value) = Result(catching: { try JSONValue.parse(result) })
		else { return false }
		return value.objectFields["data"]?.objectFields["kind"]?.stringValue == "prepared"
	}

	private static func preparation(of call: LiveVerdict.ParsedCall) -> [String: JSONValue] {
		call.arguments?["preparation"]?.objectFields ?? [:]
	}

	static func shown(_ shapes: [LiveChangeShape]) -> String {
		shapes.isEmpty ? "no change" : shapes.map(\.description).joined(separator: ", ")
	}
}
