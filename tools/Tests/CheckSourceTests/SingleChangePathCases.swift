extension SourceCases {
	static let reviewTypes = "\(review)/ReviewTypes.swift"
	static let tokenMinted = [
		"let token = ReviewControlToken(ref: ref, secret: UUID())",
		"let token = ReviewControlToken.init(ref: ref, secret: UUID())",
		"let token = ReviewControlToken .init(ref: ref, secret: secret)",
		"let make = ReviewControlToken.init",
		"let token: ReviewControlToken = .init(ref: ref, secret: UUID())",
		"func token() -> ReviewControlToken { .init(ref: ref, secret: secret) }",
		"let controls = ReviewControls.armed(.approveOrCancel, .init(ref: ref, secret: secret))",
		"let tokens: [ReviewControlToken] = [.init(\n\tref: ref,\n\tsecret: secret)]",
		"static func again(_ ref: ReviewRef) -> Self { Self(ref: ref, secret: UUID()) }",
	]
	static let tokenUsed =
		"let used: ReviewControlToken\n"
		+ "func token(on desk: WorkoutReviewDesk) async throws -> ReviewControlToken {}\n"
		+ "guard case .armed(_, let token) = snapshot.controls else { return }\n"
		+ "extension ReviewControlToken {\n\tfunc moved(at head: ULID) -> Self { self }\n}\n"
		+ "let delivery = Delivery(ref: ref, head: head, presence: .armed(secret))\n"
		+ "let other = delivery.controls(.approveOrCancel)"
	static let singleChangeFiles = [
		"\(review)/WorkoutReviewDesk.swift", "\(coachTests)/ReviewApprovalTests.swift",
		"apps/ios/Enduragent/Chat/ConfirmedPreviewCard.swift",
		"apps/ios/EnduragentTests/FixtureReviewTests.swift",
		"apps/ios/EnduragentUITests/ReviewProofs.swift",
		"apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachLiveChecks/LiveVerdict.swift",
	]
	static let singleChangeSpellings = [
		"let name = GatedToolName.intervalsCreateWorkout",
		"func run(_ input: GatedToolInput) {}",
		"let policy = ProposalPolicy.default",
		"let proposal: PendingProposal? = nil",
		"let reviews = SingleProposalReviews(ledger: ledger)",
		"private let reviews: any WorkoutReviews",
		"let intent = CalendarWriteIntent(key: key)",
		"let operation: CalendarWriteOperation = .init(write)",
		"let recovery = CalendarWriteRecovery()",
		"let snapshot = ProposalReviewSnapshot(proposal)",
		"let card = ProposalReviewCard(snapshot: snapshot)",
		"if snapshot.authority == ReviewAuthority.thisDevice {}",
		"case .cancelledUnknown(let review as CancelledUnknownReview):",
		"let buttons: DisabledReviewButtons = .none",
		"let delivery = ReviewDelivery.fresh",
		"let create = ChatCalendarCreate(date: date)",
		"let id = ChatExternalID(rawValue: raw)",
		"await model.decide(.retryRemaining(token))",
		"case .retryRemainingOrCancel(let token):",
		"await model.decide(.checkAgainWithoutToken(ref))",
		"let placement = ReviewPlacement.endOfConversation",
		"case turnStopping",
		"guard case . turnStopping = block else { return }",
		"let external = IntervalsSerializer.chatExternalId(for: create)",
		"let tool = ToolName.intervalsCreateWorkout",
		"let tools: [ToolName] = [.intervalsCreateStrengthWorkout, .intervalsUpdateWorkout]",
		"case .intervalsDeleteWorkout: return nil",
	]
	static let shippedFiles = [
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Loop/CalendarTools.swift",
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Loop/PromptResources/skills/intervals-icu.md",
		"apps/ios/Enduragent/Fixtures/FirstWeekFixture.swift",
	]
	static let oldToolNames = [
		"name: \"intervals_create_workout\"",
		"Use `intervals_create_strength_workout` for strength.",
		"call intervals_update_workout or intervals_delete_workout",
	]
	static let laterTypes = [
		"let desk: WorkoutReviewDesk", "let review: WorkoutReview", "let pending: PendingReview",
		"let proposal: LegacyProposal", "let body: LegacyProposalBody", "let write: LegacyWrite",
		"let kind = LegacyKind.pendingProposal", "let cleared = LegacyKind.proposalCleared",
		"let scope = RecordScope.synced([], includeLegacy: [.reviewWrite, .reviewCancelledUnknown])",
		"let canceled: ReviewCancelledUnknownBody",
		"let note = TranscriptNote.Content.cancelledUnknown",
		"let set = ControlSet.checkAgainOrCancel",
		"let decision = ReviewDecision.checkAgain(token)",
		"let tool = ToolName.planSave", "let unsafe = ReplayUnsafeToolName.planSave",
		"let placement = ReviewPlacement.preparedEarlier",
		"let after = ReviewPlacement.afterTurn(turn)",
		"let block = ReviewBlock.reviewedBeforeUpgrade",
		"let tool = ToolName.prepareWorkoutChanges",
		"let pendingTool = \"get_pending_workout_changes\"",
		"let prepare = \"prepare_workout_changes\"", "struct PlanSaveConfirmation {}",
		"struct ReviewCardView {}", "let writes = WorkoutReviewsList()",
		"let key = Catalog.reviewStorageUnavailable", "let stopping = isTurnStopping",
	].joined(separator: "\n")

	static let tokenCases: [SourceCase] =
		tokenMinted.flatMap { source in
			mintedOutside.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source], finding: "[minted-in-one-file]")
			}
		}
		+ [
			.accepts(
				"accepts every token spelling in its own file",
				[reviewTypes: tokenMinted.joined(separator: "\n")]),
			.accepts(
				"accepts a token used, extended or minted through a delivery elsewhere",
				Dictionary(uniqueKeysWithValues: mintedOutside.map { ($0, tokenUsed) })),
		]

	static let deletedNameCases: [SourceCase] = singleChangeSpellings.flatMap { source in
		singleChangeFiles.map { file in
			.rejects(
				"rejects \(source) in \(file)", [file: source],
				finding: "[single-change-path-deleted]")
		}
	}

	static let oldToolCases: [SourceCase] = oldToolNames.flatMap { source in
		shippedFiles.map { file in
			.rejects(
				"rejects \(source) in \(file)", [file: source],
				finding: "[single-change-path-deleted]")
		}
	}

	static let keptNameCases: [SourceCase] = [
		.accepts(
			"accepts the review types, legacy kinds and later types beside the deleted path",
			Dictionary(uniqueKeysWithValues: singleChangeFiles.map { ($0, laterTypes) })),
		.accepts(
			"accepts the old tool names where tests prove they are no longer offered",
			[
				"\(coachTests)/TurnToolInputTests.swift": oldToolNames.joined(separator: "\n"),
				"apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachLiveChecks/LiveCoachHelperTests.swift":
					oldToolNames[0],
			]),
		.accepts(
			"accepts the deleted names outside the app",
			[
				"tools/fixtures/Build6833d90fStoreSeed.swift":
					singleChangeSpellings.joined(separator: "\n") + "\n" + oldToolNames[0],
				"CHANGELOG.md": "GatedToolName and intervals_create_workout went in 9.2.",
			]),
	]

	static let singleChangePathDeleted: [SourceCase] =
		tokenCases + deletedNameCases + oldToolCases + keptNameCases
}
