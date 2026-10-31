extension SourceCases {
	static let review = "apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Review"
	static let calendarWriter = "\(review)/CalendarWriter.swift"
	static let workoutReview = "\(review)/WorkoutReview.swift"
	static let mintedOutside = [
		"\(review)/WorkoutReviewDesk.swift", "\(coachTests)/WorkoutReviewTransitionTests.swift",
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoachFixtures/FakeWriter.swift",
	]
	static let receiptDecode = "let receipt = try values.decode(Receipt.self, forKey: .receipt)"

	static let mintedInOneFile: [SourceCase] =
		[
			"extension Receipt {}",
			"extension Receipt: CustomStringConvertible {}",
			"let receipt = Receipt(event: event, answeredAt: now)",
			"let receipt = Receipt.init(from: decoder)",
			"extension SendAttempt {}",
			"let attempt = SendAttempt(change: change, claim: claim, sentAt: now)",
			"let attempt = SendAttempt.init(change: change, claim: claim, sentAt: now)",
			receiptDecode,
			"let receipt = try values.decodeIfPresent(Receipt.self, forKey: .receipt)",
		].flatMap { source in
			mintedOutside.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source], finding: "[minted-in-one-file]")
			}
		}
		+ [calendarWriter, workoutReview].map { owner in
			.rejects(
				"rejects a decode of a Receipt alone in its owner \(owner)",
				[owner: receiptDecode], finding: "[minted-in-one-file]")
		}
		+ [
			.accepts(
				"accepts each value minted and extended in its own file",
				[
					calendarWriter:
						"struct Receipt {}\nextension Receipt {}\nlet receipt = Receipt(event: e)",
					workoutReview:
						"struct SendAttempt {}\nextension SendAttempt {}\n"
						+ "let attempt = SendAttempt(change: c)",
				]),
			.accepts(
				"accepts names that only contain Receipt or SendAttempt",
				[
					"\(review)/ProposalReviewSnapshot.swift":
						"let receipt = ReviewReceipt(index: 0, result: .uncertain)",
					"\(review)/WorkoutReviewDocument.swift":
						"let document = SendAttemptDocument(attempt)\nextension SendAttemptDocument {}\n"
						+ "let decoded = try values.decode(ReceiptDocument.self, forKey: .receipt)",
					"\(coachTests)/WorkoutReviewTransitionTests.swift":
						"guard case .saved(let receipt) = result else { return }\nlet r: Receipt",
				]),
			.accepts(
				"accepts a file that declares its own type of that name",
				[
					mintedOutside[2]:
						"private struct Receipt: Encodable {}\nlet receipt = Receipt()\n"
						+ receiptDecode,
					mintedOutside[0]: "private enum SendAttempt {}\nextension SendAttempt {}",
				]),
			.accepts(
				"accepts the patterns outside the package",
				[
					"apps/ios/EnduragentPhoneTests/Proof.swift":
						"private struct Receipt: Decodable {}\n\(receiptDecode)",
					"tools/Tests/Example.swift": "let receipt = Receipt(event: e)",
				]),
		]
}
