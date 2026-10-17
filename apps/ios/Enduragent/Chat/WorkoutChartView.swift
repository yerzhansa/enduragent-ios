import EnduragentCoach
import SwiftUI

struct WorkoutChartView: View {
	var display: DisplayLocale
	var chart: WorkoutChartModel

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(display.say(axisTitle))
				.font(.caption)
				.foregroundStyle(.secondary)
			Canvas { context, size in
				let plot = CGRect(
					x: Self.gutter, y: 0, width: max(size.width - Self.gutter, 0),
					height: size.height)
				drawTicks(in: &context, plot: plot)
				drawSegments(in: &context, plot: plot)
			}
			.frame(height: 88)
			HStack {
				Text(display.integer(0))
				Spacer()
				Text(display.say(Catalog.chatAttachmentMinutes, ["number": .integer(totalMinutes)]))
			}
			.font(.caption2)
			.foregroundStyle(.secondary)
			.padding(.leading, Self.gutter)
		}
		.accessibilityHidden(true)
	}

	private static let gutter: CGFloat = 32

	private var axisTitle: CatalogKey {
		switch chart.unit {
		case .percentOfFTP: Catalog.workoutsChartPercentOfFTP
		case .watts: Catalog.workoutsChartWatts
		case .zone: Catalog.trainingRideZone
		}
	}

	private var totalMinutes: Int { (chart.durationSeconds + 30) / 60 }

	private func drawTicks(in context: inout GraphicsContext, plot: CGRect) {
		for tick in chart.ticks {
			let y = height(of: tick, in: plot)
			var line = Path()
			line.move(to: CGPoint(x: plot.minX, y: y))
			line.addLine(to: CGPoint(x: plot.maxX, y: y))
			context.stroke(
				line, with: .color(Color(.separator)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
			context.draw(
				Text(display.number(tick, precision: .compact))
					.font(.caption2)
					.foregroundStyle(.secondary),
				at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
		}
	}

	private func drawSegments(in context: inout GraphicsContext, plot: CGRect) {
		guard chart.durationSeconds > 0 else { return }
		let scale = plot.width / CGFloat(chart.durationSeconds)
		var start = plot.minX
		for segment in chart.segments {
			let width = CGFloat(segment.durationSeconds) * scale
			let frame = CGRect(x: start, y: plot.minY, width: width, height: plot.height)
			start += width
			switch segment {
			case .steady(_, let target):
				context.fill(bar(frame, from: target, to: target, in: plot), with: .color(.accentColor))
			case .ramp(_, let begin, let end):
				context.fill(bar(frame, from: begin, to: end, in: plot), with: .color(.accentColor))
			case .range(_, let low, let high):
				context.fill(
					bar(frame, from: high, to: high, in: plot),
					with: .color(.accentColor.opacity(0.35)))
				context.fill(bar(frame, from: low, to: low, in: plot), with: .color(.accentColor))
			case .open:
				context.fill(
					Path(CGRect(x: frame.minX, y: plot.maxY - 2, width: frame.width, height: 2)),
					with: .color(Color(.separator)))
			}
		}
	}

	private func bar(_ frame: CGRect, from begin: Double, to end: Double, in plot: CGRect) -> Path {
		var path = Path()
		path.move(to: CGPoint(x: frame.minX, y: plot.maxY))
		path.addLine(to: CGPoint(x: frame.minX, y: height(of: begin, in: plot)))
		path.addLine(to: CGPoint(x: frame.maxX, y: height(of: end, in: plot)))
		path.addLine(to: CGPoint(x: frame.maxX, y: plot.maxY))
		path.closeSubpath()
		return path
	}

	private func height(of value: Double, in plot: CGRect) -> CGFloat {
		let share = min(max(value / chart.ceiling, 0), 1)
		return plot.minY + plot.height * (1 - CGFloat(share))
	}
}
