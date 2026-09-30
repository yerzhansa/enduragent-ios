import Foundation

public enum ReviewSummary: Sendable, Equatable {
	case supplied(String)
	case createWorkout(name: String, date: CivilDate)
	case createStrengthWorkout(name: String, date: CivilDate)
	case deleteWorkout
	case updateWorkout(date: CivilDate?, name: String?, descriptionChanged: Bool)
	case planSave(name: String)

	package init(_ input: GatedToolInput) {
		switch input {
		case .createWorkout(let date, let workout):
			self = .createWorkout(name: workout.name, date: date)
		case .createStrengthWorkout(let date, let name, _):
			self = .createStrengthWorkout(name: name, date: date)
		case .deleteWorkout:
			self = .deleteWorkout
		case .updateWorkout(let update):
			self = .updateWorkout(
				date: update.date, name: update.name, descriptionChanged: update.description != nil)
		case .planSave(let headline):
			self = .planSave(name: headline.name)
		}
	}

	public func sentence(in phrasebook: CatalogPhrasebook) -> String {
		switch self {
		case .supplied(let text):
			return text
		case .createWorkout(let name, let date):
			return phrasebook.say(
				Catalog.coachProposalCreate, ["name": name, "date": date.rawValue])
		case .createStrengthWorkout(let name, let date):
			return phrasebook.say(
				Catalog.coachProposalCreateStrength, ["name": name, "date": date.rawValue])
		case .deleteWorkout:
			return phrasebook.say(Catalog.coachProposalDeleteFallback, [:])
		case .updateWorkout(let date, let name, let descriptionChanged):
			var fields: [String] = []
			if let date {
				fields.append(phrasebook.say(Catalog.coachProposalDate, ["date": date.rawValue]))
			}
			if let name {
				fields.append(phrasebook.say(Catalog.coachProposalName, ["name": name]))
			}
			if descriptionChanged {
				fields.append(phrasebook.say(Catalog.coachProposalDescription, [:]))
			}
			let detail =
				fields.isEmpty
				? phrasebook.say(Catalog.coachProposalSelectedFields, [:])
				: fields.joined(separator: ", ")
			return phrasebook.say(Catalog.coachProposalUpdateFallback, ["detail": detail])
		case .planSave(let name):
			return name.isEmpty
				? phrasebook.say(Catalog.coachProposalSavePlan, [:])
				: phrasebook.say(Catalog.coachProposalSavePlanDetail, ["detail": name])
		}
	}
}
