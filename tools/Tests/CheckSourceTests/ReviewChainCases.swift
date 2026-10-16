extension SourceCases {
	static let records = "apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records"
	static let reviewChainBuilders = [
		"\(records)/ReviewChain.swift", "\(records)/RecordCodec.swift",
		"\(records)/DeviceLocalCodec.swift", "\(records)/RecordEnvelopePayload.swift",
	]
	static let reviewChainOutside = [
		"\(review)/WorkoutReviewDesk.swift", "\(records)/Ledger.swift",
		"\(records)/WorkoutReviewBody.swift",
	]
	static let reviewChainBodies = [
		"let body = WorkoutReviewBody(review: review)",
		"let body = WorkoutReviewBody.init(review: review)",
		"let marker = ReviewPreparingBody(chatId: chat, turn: turn, attempt: attempt)",
		"let marker = ReviewPreparingBody .init(chatId: chat, turn: turn, attempt: attempt)",
	]

	static let reviewChainOnly: [SourceCase] =
		reviewChainBodies.flatMap { source in
			reviewChainOutside.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source], finding: "[review-chain-only]")
			}
		}
		+ reviewChainBuilders.map { file in
			.accepts(
				"accepts both review chain bodies built in \(file)",
				[file: reviewChainBodies.joined(separator: "\n")])
		}
		+ [
			.accepts(
				"accepts the record cases and the operation that share the name",
				[
					reviewChainOutside[0]:
						"let body: RecordBody = .deviceLocal(.workoutReview(body))\n"
						+ "let marker: RecordBody = .deviceLocal(.reviewPreparing(marker))\n"
						+ "let operation = OperationID.workoutReview(id, revision)",
					reviewChainOutside[2]:
						"package struct WorkoutReviewBody: Sendable, Equatable {}\n"
						+ "case workoutReview(WorkoutReviewBody)",
				]),
			.accepts(
				"accepts the bodies built outside the package's main target",
				[
					"\(coachTests)/ReviewChainLogTests.swift": reviewChainBodies[0],
					"\(coachFixtures)/FixtureReviews.swift": reviewChainBodies[2],
				]),
		]
}
