import EnduragentCoach
import SwiftUI

struct ReviewCardView: View {
	var model: ShellModel
	var card: ReviewCard
	var count: Int

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(card.title(in: display))
				.font(.headline)
				.accessibilityIdentifier("chat.preview.card.title")
			Text(card.heading(of: count, in: display))
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.accessibilityIdentifier("chat.preview.card.heading")
			if let status = card.status(in: display) {
				Text(status)
					.font(.subheadline.weight(.semibold))
					.accessibilityIdentifier("chat.preview.card.status")
			}
			ForEach(Array(card.changes(in: display).enumerated()), id: \.offset) { _, change in
				Text(change)
					.accessibilityIdentifier("chat.preview.card.change")
			}
			if let chart = card.chart {
				WorkoutChartView(display: display, chart: chart)
			}
			if !steps.isEmpty {
				Text(steps.joined(separator: "\n"))
					.font(.callout)
					.accessibilityIdentifier("chat.preview.card.steps")
			}
			if let load = card.load(in: display) {
				Text(load)
					.font(.footnote)
					.foregroundStyle(.secondary)
					.accessibilityIdentifier("chat.preview.card.load")
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("chat.preview.card.\(card.index)")
	}

	private var display: DisplayLocale { model.displayLocale }

	private var steps: [String] { card.lines(in: display) }
}
