import Foundation

public struct ReviewInstructions: Sendable, Equatable {
	package enum Content: Sendable, Equatable {
		case cycling(IntervalsWorkoutInput)
		case supplied(String)
	}

	package let content: Content

	public func lines(in phrasebook: CatalogPhrasebook) -> [String] {
		switch content {
		case .cycling(let workout):
			IntervalsSerializer.description(workout, phrasebook: phrasebook)
		case .supplied(let text):
			text.isEmpty
				? []
				: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		}
	}
}
