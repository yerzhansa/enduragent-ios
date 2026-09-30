import Foundation

package protocol TurnEvidence: Sendable {
	func block(for training: TrainingConnection, attempt: AttemptID, now: Date)
		async throws(CancellationError) -> EvidenceBlock
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

	package func block(for training: TrainingConnection, attempt: AttemptID, now: Date)
		async throws(CancellationError) -> EvidenceBlock
	{
		guard training.account != .unconnected else { return EvidenceBlock(wellnessLine: nil) }
		let today = IntervalsPolicy.today(now: now, timeZone: clock.timeZone)
		let days: [WellnessDay]
		do {
			days = try await training.client.fetchWellness(
				oldest: today.adding(days: -(Self.days - 1)), newest: today)
		} catch is CancellationError {
			throw CancellationError()
		} catch {
			diagnostics.record(.evidenceUnavailable(attempt, TrainingFailure(error)))
			return EvidenceBlock(wellnessLine: nil)
		}
		return EvidenceBlock(wellnessLine: days.last.flatMap(Self.line))
	}

	private static func line(_ day: WellnessDay) -> String? {
		var parts: [String] = []
		if let fitness = day.fitness {
			parts.append("Fitness \(WellnessDay.formattedNumber(fitness, fractionDigits: 1))")
		}
		if let fatigue = day.fatigue {
			parts.append("Fatigue \(WellnessDay.formattedNumber(fatigue, fractionDigits: 1))")
		}
		if let form = day.form {
			parts.append("Form \(signed(form))")
		}
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}

	private static func signed(_ value: Double) -> String {
		let body = WellnessDay.formattedNumber((value * 10).rounded() / 10, fractionDigits: 1)
		return value > 0 ? "+\(body)" : body
	}
}
