import Foundation

package struct WorkoutReviewBody: Sendable, Equatable {
	package let review: WorkoutReview

	package var chatId: ChatID { review.chat }
}
