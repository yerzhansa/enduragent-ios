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
		"let make = WorkoutReviewBody.init",
		"let marker: ReviewPreparingBody = .init(chatId: chat, turn: turn, attempt: attempt)",
		"let body: RecordBody = .deviceLocal(.workoutReview(.init(review: next)))",
		"let marker = DeviceLocalRecordBody.reviewPreparing(.init(chatId: chat, turn: turn, attempt: id))",
	]
	static let reviewChainRenamings = [
		"typealias Body = WorkoutReviewBody",
		"typealias Marker = EnduragentCoach.ReviewPreparingBody",
		"extension WorkoutReviewBody {\n\tstatic func of(_ review: WorkoutReview) -> Self { Self(review: review) }\n}",
		"extension ReviewPreparingBody: CustomStringConvertible {}",
	]
	static let reviewChainBodyFiles = [
		"\(records)/WorkoutReviewBody.swift", "\(records)/ReviewPreparingBody.swift",
	]

	static let reviewChainOnly: [SourceCase] =
		reviewChainBodies.flatMap { source in
			reviewChainOutside.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source], finding: "[review-chain-only]")
			}
		}
		+ reviewChainRenamings.flatMap { source in
			[reviewChainOutside[0], reviewChainOutside[1], reviewChainBuilders[0]].map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source], finding: "[review-chain-only]")
			}
		}
		+ reviewChainBodyFiles.map { file in
			.accepts(
				"accepts the body types renamed and extended in \(file)",
				[file: reviewChainRenamings.joined(separator: "\n")])
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
