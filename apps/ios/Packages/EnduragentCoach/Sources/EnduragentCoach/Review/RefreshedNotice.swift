import Foundation

extension ReviewProjection {
	static func notice(of review: WorkoutReview) -> ReviewNotice? {
		guard case .waiting(.approval(.refreshed(let differences))) = review.stage else {
			return nil
		}
		return ReviewNotice(
			kind: .refreshedAfterStaleTarget,
			key: review.work.finished.isEmpty
				? Catalog.workoutsRefreshedNothingChanged
				: Catalog.workoutsRefreshedNothingElseChanged,
			vars: ["service": "intervals.icu"], differences: differences)
	}
}

extension TargetDifference {
	func sentences(in display: DisplayLocale) -> [String] {
		let changed = fields
		let workout = CatalogArgument.text(Self.name(before.name, in: display))
		return SnapshotField.allCases.filter(changed.contains).map { field in
			switch field {
			case .date:
				display.say(
					Catalog.workoutsRefreshedDate,
					["workout": workout, "from": .day(before.date), "to": .day(after.date)])
			case .name:
				display.say(
					Catalog.workoutsRefreshedName,
					["workout": workout, "to": .text(Self.name(after.name, in: display))])
			case .duration:
				display.say(
					Catalog.workoutsRefreshedDuration,
					[
						"workout": workout,
						"from": Self.amount(Self.minutes(before.durationSeconds), in: display),
						"to": Self.amount(Self.minutes(after.durationSeconds), in: display),
					])
			case .description:
				display.say(Catalog.workoutsRefreshedDescription, ["workout": workout])
			case .load:
				display.say(
					Catalog.workoutsRefreshedLoad,
					[
						"workout": workout, "from": Self.amount(before.load, in: display),
						"to": Self.amount(after.load, in: display),
					])
			case .structure:
				display.say(Catalog.workoutsRefreshedStructure, ["workout": workout])
			}
		}
	}

	private static func name(_ name: String?, in display: DisplayLocale) -> String {
		name ?? display.say(Catalog.coachProposalUnnamed)
	}

	private static func minutes(_ seconds: Int?) -> Int? {
		seconds.map(ReviewProjection.minutes(ofSeconds:))
	}

	private static func amount(_ value: Int?, in display: DisplayLocale) -> CatalogArgument {
		.text(display.number(value.map(Double.init), precision: .whole))
	}
}
