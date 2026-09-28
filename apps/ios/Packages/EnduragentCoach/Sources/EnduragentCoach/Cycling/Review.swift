import Foundation

package enum WorkoutReview {
	package static let sessionClusterGapMinutes = 30
	package static let windowDays = 7
	package static let emptyWindow =
		"No activity in the last 7 days — want me to look further back?"
	package static let numbersFooter = "Reply 'show numbers' for the full breakdown."
	package static let deeperFooter = "For a deeper analysis, type /review deep."

	package static func staleWindow(daysAgo: Int) -> String {
		"Your last session was \(daysAgo) days ago — want me to review that?"
	}
}
