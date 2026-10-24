extension SourceCases {
	static let coachSources = "apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach"
	static let chainAppendCallers = [
		"\(records)/ChainAppend.swift", "\(records)/ReviewChain.swift",
		"\(records)/RecordLog.swift",
		"\(coachSources)/Plans/Plans.swift", "\(coachSources)/Plans/PlanSave.swift",
	]
	static let chainAppendOutside = [
		"\(records)/Ledger.swift", "\(records)/ReviewOutcomeBody.swift",
		"\(review)/WorkoutReviewDesk.swift", "\(coachSources)/Chat/ChatRecords.swift",
		"\(coachSources)/Coach.swift", "\(coachSources)/Plans/Saved/SavedPlans.swift",
		"\(coachSources)/PlansExtra.swift",
	]
	static let chainAppendCalls = [
		"let record = try await ledger.append(body, stamp: stamp, after: head, in: query)",
		"let record = try await append(\n\t.deviceLocal(.workoutReview(body)), stamp: stamp,\n\tafter: head, in: Self.chain(of: chat))",
		"_ = try await append(.synced(body), stamp: stamp(for: id), after: head, in: query)",
		"let write = ledger.append(_:stamp:after:in:)",
		"let newest = try await ledger.newest(query)",
		"let head = try await newest(query).head",
		"switch try await ledger . newest (Self.chain(of: chat)) {}",
		"let chats = try await ledger.chats(holding: .workoutReview)",
		"let chats = try await chats(holding: .workoutReview)",
		"let all = try await chain.chats(holding: .deviceLocal([.workoutReview]))",
	]
	static let chainAppendLookalikes =
		"try await append(bodies.map(RecordBody.synced), locality: .synced, stamp: stamp)\n"
		+ "out.append(Character(scalar))\n"
		+ "claims[claim.turn, default: []].append(record)\n"
		+ "events.append(.finished(reason: .stop, usage: summedUsage()))\n"
		+ "lines.append(line(stamp: stamp))\nlet next = move(after: head)\n"
		+ "let head = try await ledger.head(of: query)\n"
		+ "let review = try await ledger.newestReview(chat: chat)\n"
		+ "let chats = try await ledger.reviewChats()\n"
		+ "let newestPlan = plans.last\n"
		+ "self.newest = newest\n"
		+ "let item = URLQueryItem(name: \"newest\", value: range.newest.rawValue)\n"
		+ "let details = \"oldest (\\(oldest)) is after newest (\\(newest)).\"\n"
		+ "_ = try await ledger.commit(review: next, stamp: stamp, after: head)"

	static let chainAppendCallerRule: [SourceCase] =
		chainAppendCalls.flatMap { source in
			chainAppendOutside.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source],
					finding: "[chain-append-callers]")
			}
		}
		+ chainAppendCallers.map { file in
			.accepts(
				"accepts every chain doorway call in \(file)",
				[file: chainAppendCalls.joined(separator: "\n")])
		}
		+ chainAppendOutside.map { file in
			.accepts(
				"accepts calls that only share a name or a label in \(file)",
				[file: chainAppendLookalikes])
		}
		+ [
			.accepts(
				"accepts chain doorway calls outside the package's main target",
				[
					"\(coachTests)/ReviewChainLogTests.swift": chainAppendCalls[4],
					"\(coachFixtures)/InMemoryRecordLog.swift": chainAppendCalls[9],
					"\(coachFixtures)/FaultInjectingRecordLog.swift": chainAppendCalls[0],
				])
		]
}
