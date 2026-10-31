extension SourceCases {
	static let planSaveSeparateReviews = [
		"\(review)/WorkoutReviewDesk.swift", "\(review)/Plan/ReviewPlans.swift",
	]
	static let planSaveSeparatePlans = ["\(plans)/Plans.swift", "\(plans)/Saved/PlanHistory.swift"]
	static let planNames = [
		"let id: PlanConfirmationID",
		"struct PlanSaveConfirmation {}",
		"let id: SavedPlanID",
		"let plans = SavedPlans(owned: records)",
		"let document: PlanDocument",
	]
	static let reviewNames = [
		"let review: WorkoutReview",
		"let id: WorkoutReviewID",
		"let summary: ReviewSummary",
		"let log: any ReviewChainLog",
		"let token = ReviewControlToken.self",
	]
	static let planLookalikesInReview =
		"case planSave(name: String)\ncase .planSave(let name): name\n"
		+ "let saves = summary.planConfirmations\nlet plan = savedPlan\nlet planDocumentText = text"
	static let reviewLookalikesInPlans =
		"let chats = try await ledger.reviewChats()\nlet ending: TurnEnding\n"
		+ "let reviewer = Reviewer()\nlet head: RecordHead\nlet key: DraftKey"

	static let planSaveSeparate: [SourceCase] =
		planNames.flatMap { source in
			planSaveSeparateReviews.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source], finding: "[plan-save-separate]")
			}
		}
		+ reviewNames.flatMap { source in
			planSaveSeparatePlans.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source], finding: "[plan-save-separate]")
			}
		}
		+ planSaveSeparateReviews.map { file in
			.accepts(
				"accepts ReviewSummary.planSave and names that only share a plan word in \(file)",
				[file: planLookalikesInReview])
		}
		+ planSaveSeparatePlans.map { file in
			.accepts(
				"accepts names that only share a review word in \(file)",
				[file: reviewLookalikesInPlans])
		}
		+ [
			.accepts(
				"accepts plan and review names together outside Plans and Review",
				[
					"\(coachSources)/Chat/ChatRecords.swift":
						(planNames + reviewNames).joined(separator: "\n"),
					"\(coachTests)/PlanChainTests.swift": reviewNames.joined(separator: "\n"),
					"\(coachTests)/WorkoutReviewTests.swift": planNames.joined(separator: "\n"),
				])
		]
}
