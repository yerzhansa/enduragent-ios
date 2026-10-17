import Foundation
import ToolSupport

extension SourceChecker {
	static let iosSwiftSource = #"^apps\/ios\/.*\.swift$"#
	static let shippedSource =
		#"^apps\/ios\/(?:Enduragent\/|Packages\/EnduragentCoach\/Sources\/).*\.(?:swift|md)$"#
	static let singleChangeNames = [
		#"\b(?:GatedToolName|GatedToolInput|ProposalPolicy|PendingProposal"#
			+ #"|SingleProposalReviews|WorkoutReviews|CalendarWriteIntent|CalendarWriteOperation"#
			+ #"|CalendarWriteRecovery|ProposalReviewSnapshot|ProposalReviewCard|ReviewAuthority"#
			+ #"|CancelledUnknownReview|DisabledReviewButtons|ReviewDelivery|ChatCalendarCreate"#
			+ #"|ChatExternalID)\b"#,
		#"(?:\.\s*|\bcase\s+)(?:retryRemaining(?:OrCancel)?|checkAgainWithoutToken"#
			+ #"|endOfConversation|turnStopping|chatExternalId)\b"#,
		#"\bintervals(?:Create(?:Strength)?Workout|UpdateWorkout|DeleteWorkout)\b"#,
	]
	static let singleChangeTools =
		#"\bintervals_(?:create_(?:strength_)?workout|update_workout|delete_workout)\b"#

	func checkSingleChangePath(_ source: SourceFile) throws {
		let file = source.file
		let text = source.text
		let named =
			try patterns.test(Self.iosSwiftSource, file)
			&& Self.singleChangeNames.contains { try patterns.test($0, text) }
		let offered =
			try patterns.test(Self.shippedSource, file)
			&& patterns.test(Self.singleChangeTools, text)
		if named || offered { try findings.report(file, "single-change-path-deleted") }
	}
}
