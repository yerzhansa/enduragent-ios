import Foundation

public enum ReviewSummary: Sendable, Equatable {
	case supplied(String)
	case createWorkout(name: String, date: CivilDate)
	case createStrengthWorkout(name: String, date: CivilDate)
	case deleteWorkout
	case updateWorkout(date: CivilDate?, name: String?, descriptionChanged: Bool)
	case planSave(name: String)

	public func sentence(in display: DisplayLocale) -> String {
		switch self {
		case .supplied(let text):
			return text
		case .createWorkout(let name, let date):
			return display.say(
				Catalog.coachProposalCreate, ["name": .text(name), "date": .day(date)])
		case .createStrengthWorkout(let name, let date):
			return display.say(
				Catalog.coachProposalCreateStrength, ["name": .text(name), "date": .day(date)])
		case .deleteWorkout:
			return display.say(Catalog.coachProposalDeleteFallback, [:])
		case .updateWorkout(let date, let name, let descriptionChanged):
			var fields: [String] = []
			if let date {
				fields.append(display.say(Catalog.coachProposalDate, ["date": .day(date)]))
			}
			if let name {
				fields.append(display.say(Catalog.coachProposalName, ["name": .text(name)]))
			}
			if descriptionChanged {
				fields.append(display.say(Catalog.coachProposalDescription, [:]))
			}
			let detail =
				fields.isEmpty
				? display.say(Catalog.coachProposalSelectedFields, [:])
				: fields.joined(separator: ", ")
			return display.say(Catalog.coachProposalUpdateFallback, ["detail": .text(detail)])
		case .planSave(let name):
			return name.isEmpty
				? display.say(Catalog.coachProposalSavePlan, [:])
				: display.say(Catalog.coachProposalSavePlanDetail, ["detail": .text(name)])
		}
	}
}
