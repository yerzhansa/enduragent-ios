extension SourceCases {
	static let planMintings = [
		(
			owner: planSave, name: "ClaimedSave",
			mintings: [
				"let claimed = ClaimedSave(confirmation: c, claim: claim, decided: hlc)",
				"let claimed = ClaimedSave.init(confirmation: c, claim: claim, decided: hlc)",
				"extension ClaimedSave {}",
			]
		),
		(
			owner: "\(plans)/PlanConfirmation.swift", name: "LiveConfirmation",
			mintings: [
				"let live = LiveConfirmation(confirmation: confirmation, head: head)",
				"let live = LiveConfirmation\n\t.init(confirmation: confirmation, head: head)",
				"extension LiveConfirmation {}",
			]
		),
		(
			owner: "\(plans)/PlanCard.swift", name: "PlanSaveToken",
			mintings: [
				"let token = PlanSaveToken(ref: ref, secret: secret)",
				"let token = PlanSaveToken (ref: ref, secret: secret)",
				"extension PlanSaveToken: CustomStringConvertible {}",
			]
		),
	]
	static let planMintedOutside = [
		"\(plans)/Plans.swift", "\(coachSources)/CoachPlans.swift",
		"\(coachTests)/PlanConfirmationTests.swift",
	]

	static let planMintedInOneFile: [SourceCase] =
		planMintings.flatMap { minted in
			minted.mintings.flatMap { source in
				planMintedOutside.filter { $0 != minted.owner }.map { file in
					.rejects(
						"rejects \(source) in \(file)", [file: source],
						finding: "[minted-in-one-file]")
				}
			}
		}
		+ planMintings.map { minted in
			.accepts(
				"accepts a \(minted.name) minted and extended in \(minted.owner)",
				[minted.owner: minted.mintings.joined(separator: "\n")])
		}
		+ [
			.accepts(
				"accepts reading and passing plan values that it does not mint",
				[
					"\(plans)/Plans.swift":
						"let live: LiveConfirmation\nlet claimed: ClaimedSave? = nil\n"
						+ "func save(_ token: PlanSaveToken) {}\nlet ref = token.ref\n"
						+ "let stamp = claimed.stamp(zone: zone)",
					"\(coachTests)/PlanTapRig.swift":
						"static func token(of card: PlanCard?) -> PlanSaveToken? { nil }",
				]),
			.accepts(
				"accepts names that only contain a minted plan name",
				[
					"\(plans)/Plans.swift":
						"let a = ClaimedSaveStep(x)\nlet b = LiveConfirmationRow(y)\n"
						+ "let c = PlanSaveTokenText(z)"
				]),
		]
}
