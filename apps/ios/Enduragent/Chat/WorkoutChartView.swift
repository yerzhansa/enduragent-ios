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
				.accessibilityIdentifier("chat.preview.card.chart.unit")
			WorkoutChartLayout {
				Canvas { context, size in
					let plot = CGRect(origin: .zero, size: size)
					drawTicks(in: &context, plot: plot)
					drawSegments(in: &context, plot: plot)
				}
				.accessibilityHidden(true)
				.layoutValue(key: WorkoutChartPart.self, value: .plot)
				ForEach(Array(chart.ticks.enumerated()), id: \.offset) { _, tick in
					Text(display.number(tick, precision: .compact))
						.font(.caption2)
						.foregroundStyle(.secondary)
						.fixedSize()
						.accessibilityIdentifier("chat.preview.card.chart.tick")
						.layoutValue(key: WorkoutChartPart.self, value: .tick(share(of: tick)))
				}
				HStack {
					Text(display.integer(0))
						.accessibilityIdentifier("chat.preview.card.chart.time")
					Spacer()
					Text(
						display.say(
							Catalog.chatAttachmentMinutes, ["number": .integer(totalMinutes)])
					)
					.accessibilityIdentifier("chat.preview.card.chart.time")
				}
				.font(.caption2)
				.foregroundStyle(.secondary)
				.layoutValue(key: WorkoutChartPart.self, value: .timeline)
			}
		}
		.accessibilityElement(children: .contain)
		.accessibilityIdentifier("chat.preview.card.chart")
	}

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
				line, with: .color(Color(.separator)),
				style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
				context.fill(
					bar(frame, from: target, to: target, in: plot), with: .color(.accentColor))
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
		plot.minY + plot.height * share(of: value)
	}

	private func share(of value: Double) -> CGFloat {
		1 - CGFloat(min(max(value / chart.ceiling, 0), 1))
	}
}

private enum WorkoutChartPart: LayoutValueKey {
	case plot
	case tick(CGFloat)
	case timeline

	static let defaultValue = WorkoutChartPart.plot
}

private struct WorkoutChartLayout: Layout {
	private static let minimumPlotHeight: CGFloat = 88
	private static let spacing: CGFloat = 4

	private struct Stop {
		static let top = Stop(share: 0, extent: 0)
		static let bottom = Stop(share: 1, extent: 0)

		var share: CGFloat
		var extent: CGFloat
	}

	private struct Frame {
		var gutter: CGFloat
		var plotHeight: CGFloat
		var timelineHeight: CGFloat
		var width: CGFloat

		init(width: CGFloat, subviews: LayoutSubviews) {
			var labelWidth: CGFloat = 0
			var ticks: [Stop] = []
			var timelineHeight: CGFloat = 0
			for subview in subviews {
				if case .tick(let share) = subview[WorkoutChartPart.self] {
					let label = subview.sizeThatFits(.unspecified)
					labelWidth = max(labelWidth, label.width)
					ticks.append(
						Stop(share: share, extent: label.height + WorkoutChartLayout.spacing))
				}
			}
			let gutter = labelWidth + WorkoutChartLayout.spacing
			for subview in subviews {
				if case .timeline = subview[WorkoutChartPart.self] {
					timelineHeight =
						subview.sizeThatFits(
							ProposedViewSize(width: max(width - gutter, 0), height: nil)
						).height
				}
			}
			let stops = [Stop.top] + ticks.sorted { $0.share < $1.share } + [Stop.bottom]
			let needed = zip(stops, stops.dropFirst()).map { upper, lower in
				let room = lower.share - upper.share
				return room > 0 ? (upper.extent + lower.extent) / 2 / room : 0
			}
			self.gutter = gutter
			self.width = width
			self.timelineHeight = timelineHeight
			plotHeight = max(WorkoutChartLayout.minimumPlotHeight, needed.max() ?? 0)
		}

		var plotWidth: CGFloat { max(width - gutter, 0) }

		var height: CGFloat { plotHeight + WorkoutChartLayout.spacing + timelineHeight }
	}

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let frame = Frame(
			width: proposal.replacingUnspecifiedDimensions().width, subviews: subviews)
		return CGSize(width: frame.width, height: frame.height)
	}

	func placeSubviews(
		in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
	) {
		let frame = Frame(width: bounds.width, subviews: subviews)
		let plotOrigin = CGPoint(x: bounds.minX + frame.gutter, y: bounds.minY)
		for subview in subviews {
			switch subview[WorkoutChartPart.self] {
			case .plot:
				subview.place(
					at: plotOrigin, anchor: .topLeading,
					proposal: ProposedViewSize(width: frame.plotWidth, height: frame.plotHeight))
			case .tick(let share):
				subview.place(
					at: CGPoint(
						x: plotOrigin.x - Self.spacing, y: plotOrigin.y + frame.plotHeight * share),
					anchor: .trailing, proposal: .unspecified)
			case .timeline:
				subview.place(
					at: CGPoint(x: plotOrigin.x, y: plotOrigin.y + frame.plotHeight + Self.spacing),
					anchor: .topLeading,
					proposal: ProposedViewSize(width: frame.plotWidth, height: frame.timelineHeight)
				)
			}
		}
	}
}
