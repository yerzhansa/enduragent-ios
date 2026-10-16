extension SourceCases {
	static let records = "apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Records"
	static let reviewChainBuilders = [
		"\(records)/ReviewChain.swift", "\(records)/RecordCodec.swift",
		"\(records)/DeviceLocalCodec.swift", "\(records)/RecordEnvelopePayload.swift",
	]
	static let reviewChainOutside = [
		"\(review)/WorkoutReviewDesk.swift", "\(records)/Ledger.swift",
		"\(records)/WorkoutReviewBody.swift", "\(review)/WorkoutReviews.swift",
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
		"func a(_ r: WorkoutReview) -> WorkoutReviewBody { .init(review: r) }",
		"func b(c: ChatID, t: TurnID, x: AttemptID) -> ReviewPreparingBody { .init(chatId: c, turn: t, attempt: x) }",
		"let b: WorkoutReviewBody? = .init(review: r)",
		"func d(_ r: WorkoutReview) -> [WorkoutReviewBody] { [.init(review: r)] }",
		"func e(_ rs: [WorkoutReview]) -> [WorkoutReviewBody] { rs.map { .init(review: $0) } }",
		"let f = DeviceLocalRecordBody.workoutReview\nlet g = f(.init(review: r))",
		"func h() -> ReviewPreparingBody {\n\treturn .init(\n\t\tchatId: chat, turn: TurnID(ulid: ULID(next)),\n\t\tattempt: ids[0],\n\t)\n}",
		"static func of(_ review: WorkoutReview) -> Self { Self(review: review) }",
	]
	static let reviewChainRenamings = [
		"typealias Body = WorkoutReviewBody",
		"typealias Marker = EnduragentCoach.ReviewPreparingBody",
		"extension WorkoutReviewBody {\n\tvar chat: ChatID { review.chat }\n}",
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
				"accepts other calls that share the review chain's labels",
				[
					reviewChainOutside[0]:
						"let observed = ReplyObservedBody(chatId: chat, turn: facts.turn, attempt: attempt)\n"
						+ "let settled: TurnSettledBody = .init(\n"
						+ "\tchatId: chat, turn: turn, attempt: attempt, settlement: settlement)\n"
						+ "let claim: TurnClaimBody = .init(\n"
						+ "\tchatId: chat, turn: turn, attempt: attempt, process: process, lease: lease)\n"
						+ "let ref: ChatRef = .init(chatId: chat)\n"
						+ "let seen = observe(turn: turn, attempt: attempt)\n"
						+ "var delivery = delivery(review: intent.body.review, chat: chat)\n"
						+ "func prepare(review: WorkoutReview) {}"
				]),
			.accepts(
				"accepts the bodies built outside the package's main target",
				[
					"\(coachTests)/ReviewChainLogTests.swift": reviewChainBodies[0],
					"\(coachFixtures)/FixtureReviews.swift": reviewChainBodies[2],
				]),
		]
}
