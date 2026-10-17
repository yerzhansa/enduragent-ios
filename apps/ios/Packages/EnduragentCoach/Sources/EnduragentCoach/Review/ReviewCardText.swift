import Foundation

extension ReviewCard {
	public func title(in display: DisplayLocale) -> String {
		name.sentence(in: display)
	}

	public func heading(of count: Int, in display: DisplayLocale) -> String {
		display.say(
			Catalog.workoutsCardHeading,
			[
				"action": .text(display.say(action.title)),
				"position": .integer(index + 1), "count": .integer(count),
				"date": .day(date),
				"duration": .text(
					durationMinutes.map { Self.minutes($0, in: display) }
						?? display.say(Catalog.workoutsCardDurationUnknown)),
			])
	}

	public func changes(in display: DisplayLocale) -> [String] {
		switch action {
		case .add: return []
		case .delete: return [display.say(Catalog.workoutsCardRemoved)]
		case .edit: return edit.map { $0.lines(to: self, in: display) } ?? []
		}
	}

	public func load(in display: DisplayLocale) -> String? {
		guard action != .delete, let estimatedLoad else { return nil }
		return display.say(Catalog.workoutsCardLoad, ["load": .integer(estimatedLoad)])
	}

	public func status(in display: DisplayLocale) -> String? {
		let key: CatalogKey? =
			switch progress {
			case .remaining: nil
			case .sending: Catalog.workoutsCardProgressSending
			case .saved: Catalog.workoutsCardProgressSaved
			case .seenOnCalendar: Catalog.workoutsCardProgressSeenOnCalendar
			case .noLongerOnCalendar: Catalog.workoutsCardProgressNoLongerOnCalendar
			case .refused: Catalog.workoutsCardProgressRefused
			case .mayHaveBeenSaved: Catalog.workoutsCardProgressMayHaveBeenSaved
			}
		return key.map { display.say($0) }
	}

	fileprivate static func minutes(_ minutes: Int, in display: DisplayLocale) -> String {
		display.say(Catalog.chatAttachmentMinutes, ["number": .integer(minutes)])
	}
}

extension ReviewCard.Action {
	fileprivate var title: CatalogKey {
		switch self {
		case .add: Catalog.workoutsCardAdd
		case .edit: Catalog.workoutsCardEdit
		case .delete: Catalog.workoutsCardDelete
		}
	}
}

extension ReviewEdit {
	fileprivate func lines(to card: ReviewCard, in display: DisplayLocale) -> [String] {
		changed.map { field in
			switch field {
			case .date:
				display.say(
					Catalog.workoutsCardChangedDate,
					["from": .day(date), "to": .day(card.date)])
			case .name:
				display.say(
					Catalog.workoutsCardChangedName,
					[
						"from": .text(name ?? display.say(Catalog.coachProposalUnnamed)),
						"to": .text(card.title(in: display)),
					])
			case .duration:
				display.say(
					Catalog.workoutsCardChangedDuration,
					[
						"from": Self.amount(
							durationMinutes, in: display, ReviewCard.minutes(_:in:)),
						"to": Self.amount(
							card.durationMinutes, in: display, ReviewCard.minutes(_:in:)),
					])
			case .load:
				display.say(
					Catalog.workoutsCardChangedLoad,
					[
						"from": Self.amount(estimatedLoad, in: display, Self.integer(_:in:)),
						"to": Self.amount(card.estimatedLoad, in: display, Self.integer(_:in:)),
					])
			case .description:
				display.say(Catalog.workoutsCardChangedDescription)
			case .steps:
				display.say(Catalog.workoutsCardChangedSteps)
			}
		}
	}

	private static func amount(
		_ value: Int?, in display: DisplayLocale, _ shown: (Int, DisplayLocale) -> String
	) -> CatalogArgument {
		.text(value.map { shown($0, display) } ?? display.say(Catalog.workoutsCardUnknown))
	}

	private static func integer(_ value: Int, in display: DisplayLocale) -> String {
		display.integer(value)
	}
}
