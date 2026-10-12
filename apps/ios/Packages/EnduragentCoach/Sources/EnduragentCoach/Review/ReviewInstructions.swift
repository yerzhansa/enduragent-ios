import Foundation

public struct ReviewInstructions: Sendable, Equatable {
	package enum Content: Sendable, Equatable {
		case cycling(IntervalsWorkoutInput)
		case supplied(String)
	}

	package let content: Content

	public func lines(in display: DisplayLocale) -> [String] {
		switch content {
		case .cycling(let workout):
			IntervalsSerializer.description(workout, display: display)
		case .supplied(let text):
			text.isEmpty
				? []
				: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		}
	}
}
