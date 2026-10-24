extension SourceCases {
	static let plans = "\(coachSources)/Plans"
	static let planSave = "\(plans)/PlanSave.swift"
	static let planRecordOwners = [
		"\(plans)/SavedPlans.swift", planSave, "\(plans)/PlanConfirmation.swift",
		"\(records)/AthleteRecord.swift",
		"\(records)/RecordCodec.swift", "\(records)/RecordEnvelopePayload.swift",
		"\(records)/DeviceLocalCodec.swift",
	]
	static let planRecordOutside = [
		"\(coachSources)/Memory/Memory.swift", "\(records)/Ledger.swift",
		"\(records)/RecordBodies.swift", "\(plans)/Saved/SavedPlans.swift",
		"\(coachTests)/SavedPlanTests.swift",
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoachFixtures/FixtureRecords.swift",
	]
	static let planRecordNames = [
		"let scope = RecordQuery.Scope.synced([.savedPlan])",
		"guard case .synced(.savedPlan(let body)) = record.body else { return }",
		"let kind = SyncedKind . savedPlan",
		"let body: SavedPlanBody? = nil",
		"func keep(_ body: SavedPlanBody) {}",
		"let scope = RecordQuery.Scope.deviceLocal([.planConfirmation])",
		"guard case .deviceLocal(.planConfirmation(let body)) = record.body else { return }",
		"let kind = DeviceLocalKind . planConfirmation",
		"func keep(_ body: PlanConfirmationBody) {}",
	]
	static let planRecordLookalikes =
		"let plans = snapshot.savedPlans\nlet kind = SavedPlans.kind\nlet id: SavedPlanID\n"
		+ "let payload = SavedPlanPayload(value)\nlet saves = summary.planSaves\n"
		+ "let savedPlanCount = 1\nlet plan = claim.savedPlanID\n"
		+ "let confirmations = summary.planConfirmations\nlet id: PlanConfirmationID\n"
		+ "let step: PlanConfirmationStep\nlet kind = PlanChain.kind\n"
		+ "let payload = PlanConfirmationPayload(body)"
	static let savedPlanMintings = [
		"let body = SavedPlanBody(id: id, confirmation: c, decided: hlc, document: d)",
		"let body = SavedPlanBody.init(id: id, confirmation: c, decided: hlc, document: d)",
		"let body = SavedPlanBody\n\t.init(id: id, confirmation: c, decided: hlc, document: d)",
		"extension SavedPlanBody {}",
		"func make() -> Body { .init(id: id, confirmation: c, decided: hlc, document: d) }",
		"static func of(_ d: PlanDocument) -> Self { Self(id: i, confirmation: c, decided: h, document: d) }",
	]
	static let savedPlanMintedOutside = [
		"\(plans)/SavedPlans.swift", "\(records)/RecordCodec.swift",
		"\(coachTests)/SavedPlanTests.swift",
	]

	static let planRecordsPrivate: [SourceCase] =
		planRecordNames.flatMap { source in
			planRecordOutside.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source],
					finding: "[plan-records-private]")
			}
		}
		+ planRecordOwners.map { file in
			.accepts(
				"accepts every saved-plan record name in \(file)",
				[file: planRecordNames.joined(separator: "\n")])
		}
		+ planRecordOutside.map { file in
			.accepts(
				"accepts names that only share a saved-plan word in \(file)",
				[file: planRecordLookalikes])
		}
		+ [
			.accepts(
				"accepts saved-plan record names outside the coach package",
				[
					"tools/Tests/Example.swift": planRecordNames.joined(separator: "\n"),
					"apps/ios/Enduragent/Chat/PlanView.swift": "let kind = SyncedKind.savedPlan",
				])
		]
		+ savedPlanMintings.flatMap { source in
			savedPlanMintedOutside.map { file in
				.rejects(
					"rejects \(source) in \(file)", [file: source],
					finding: "[minted-in-one-file]")
			}
		}
		+ [
			.accepts(
				"accepts a SavedPlanBody minted and extended in PlanSave.swift",
				[planSave: savedPlanMintings.joined(separator: "\n")]),
			.accepts(
				"accepts the codec decoding a SavedPlanBody through its decoder",
				[
					"\(records)/RecordCodec.swift":
						"return .savedPlan(try SavedPlanBody.decode(payload))\n"
						+ "let id = SavedPlanID(ulid: try decodeULID(payload.id))"
				]),
		]
}
