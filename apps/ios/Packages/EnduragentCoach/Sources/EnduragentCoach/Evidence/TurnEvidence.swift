import Foundation

package protocol TurnEvidence: Sendable {
	func block(for training: TrainingConnection, now: Date) async -> EvidenceBlock
}

package struct EvidenceBlock: Sendable, Equatable {
	package let wellnessLine: String?

	package init(wellnessLine: String?) {
		self.wellnessLine = wellnessLine
	}
}

package struct WellnessEvidence: TurnEvidence {
	private static let days = 7

	private let clock: any Clock
	private let diagnostics: DiagnosticsLog

	package init(clock: any Clock, diagnostics: DiagnosticsLog) {
		self.clock = clock
		self.diagnostics = diagnostics
	}

	package func block(for training: TrainingConnection, now: Date) async -> EvidenceBlock {
		let today = IntervalsPolicy.today(now: now, timeZone: clock.timeZone)
		let days: [WellnessDay]
		do {
			days = try await training.client.fetchWellness(
				oldest: today.adding(days: -(Self.days - 1)), newest: today)
		} catch is CancellationError {
			return EvidenceBlock(wellnessLine: nil)
		} catch {
			diagnostics.record(.evidenceUnavailable(detail: String(describing: error)))
			return EvidenceBlock(wellnessLine: nil)
		}
		return EvidenceBlock(wellnessLine: days.last.flatMap(Self.line))
	}

	private static func line(_ day: WellnessDay) -> String? {
		var parts: [String] = []
		if let fitness = day.fitness {
			parts.append("Fitness \(number(fitness))")
		}
		if let fatigue = day.fatigue {
			parts.append("Fatigue \(number(fatigue))")
		}
		if let form = day.form {
			parts.append("Form \(signed(form))")
		}
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}

	private static func number(_ value: Double) -> String {
		value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
	}

	private static func signed(_ value: Double) -> String {
		let body = number((value * 10).rounded() / 10)
		return value > 0 ? "+\(body)" : body
	}
}
