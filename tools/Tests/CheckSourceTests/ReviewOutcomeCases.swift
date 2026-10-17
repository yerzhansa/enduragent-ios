extension SourceCases {
	static let reviewOutcomeWriters = [
		"\(review)/WorkoutReviewDesk.swift", "\(records)/RecordCodec.swift",
		"\(records)/RecordEnvelopePayload.swift", "\(records)/ReviewOutcomeBody.swift",
	]
	static let reviewOutcomeOutside = [
		"\(review)/WorkoutReviewDrive.swift", "\(review)/ReviewProjection.swift",
		"\(records)/ReviewChain.swift", "\(records)/AthleteRecord.swift",
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Coach.swift",
	]
	static let reviewOutcomeWrites = [
		"_ = try await ledger.commit(synced: [.reviewOutcome(summary)], stamp: stamp)",
		"let body = SyncedRecordBody.reviewOutcome(ReviewProjection.summary(of: review, ending: .completed))",
		"let record: RecordBody = .synced(.reviewOutcome(.init(\n\tchatId: chat, review: id, revision: r, after: turn, ending: .canceled, lines: [])))",
		"let bodies = [SyncedRecordBody.reviewOutcome(\n\tsummary)]",
		"let synced: SyncedRecordBody = . reviewOutcome (body)",
		"let all = summaries.map(SyncedRecordBody.reviewOutcome)",
		"let make = SyncedRecordBody.reviewOutcome\nlet body = make(summary)",
		"let body = EnduragentCoach.SyncedRecordBody.reviewOutcome(summary)",
	]
	static let reviewOutcomeReads =
		"guard case .synced(.reviewOutcome(let body)) = record.body else { return nil }\n"
		+ "if case .reviewOutcome(_) = synced { return true }\n"
		+ "switch synced { case .reviewOutcome(var body): body = body }\n"
		+ "case .reviewOutcome(let body): body.chatId\n"
		+ "let query = RecordQuery(scope: .synced([.reviewOutcome]), chatId: chat)\n"
		+ "let kind = SyncedKind.reviewOutcome\n"
		+ "case .reviewOutcome: .reviewOutcome\n"
		+ "case reviewOutcome(ReviewOutcomeBody)\n"
		+ "diagnostics.record(.reviewOutcomeUnsaved(error))\n"
		+ "let outcomes = try await ledger.reviewOutcomes(chat: chat)\n"
		+ "let summary = ReviewOutcomeBody(\n"
		+ "\tchatId: chat, review: id, revision: r, after: turn, ending: .completed, lines: [])"

	static let reviewOutcomeWriter: [SourceCase] =
		reviewOutcomeWrites.flatMap { source in
			reviewOutcomeOutside.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source],
					finding: "[review-outcome-writer]")
			}
		}
		+ reviewOutcomeWriters.map { file in
			.accepts(
				"accepts every outcome write in \(file)",
				[file: reviewOutcomeWrites.joined(separator: "\n")])
		}
		+ (reviewOutcomeOutside + ["\(review)/ReviewOutcomeNotes.swift"]).map { file in
			.accepts(
				"accepts outcome reads, kinds and summaries in \(file)",
				[file: reviewOutcomeReads])
		}
		+ [
			.accepts(
				"accepts outcome writes outside the package's main target",
				[
					"\(coachTests)/ReviewApprovalTests.swift": reviewOutcomeWrites[0],
					"\(coachFixtures)/FixtureReviews.swift": reviewOutcomeWrites[1],
				])
		]
}
