import Foundation

public struct PlannedPhoneStep: Equatable, Sendable {
	public static let variable = "ENDURAGENT_PLAN_PHONE_STEPS"

	public let id: String
	public let planned: Int

	public init(id: String, planned: Int) {
		self.id = id
		self.planned = planned
	}

	public static func text(_ steps: [PlannedPhoneStep]) -> String {
		steps.map { "\($0.id)=\($0.planned)" }.joined(separator: ",")
	}

	public static func steps(in text: String) -> [PlannedPhoneStep]? {
		var steps: [PlannedPhoneStep] = []
		for entry in text.split(separator: ",", omittingEmptySubsequences: false) {
			let parts = entry.split(separator: "=", omittingEmptySubsequences: false)
			guard parts.count == 2, !parts[0].isEmpty, let planned = Int(parts[1]), planned >= 0,
				String(planned) == parts[1]
			else { return nil }
			steps.append(PlannedPhoneStep(id: String(parts[0]), planned: planned))
		}
		return steps
	}
}
