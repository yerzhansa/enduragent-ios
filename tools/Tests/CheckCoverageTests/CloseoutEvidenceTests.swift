import Foundation
import Testing
import ToolSupport

@testable import CheckCoverage

struct CloseoutEvidenceTests {
	static let packageTests = "apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachTests/"
	static let proofs = "apps/ios/EnduragentUITests/"
	static let four = "coverage/milestone-4.json"
	static let five = "coverage/milestone-5.json"
	static let six = "coverage/milestone-6.json"

	static let mobileRows:
		[String: (evidence: [EvidencePointer], differences: [DifferencePointer])] =
			[
				"MOB01": ([closeout("lifecycle")], []),
				"MOB02": ([m4("offline-approve")], []),
				"MOB03": ([closeout("lifecycle")], []),
				"MOB04": (
					[
						.requirement(table: four, id: "X04/zone"),
						.requirement(table: four, id: "G06/midnight"),
					],
					[
						.recorded(
							record: "ADR-0083",
							says:
								"The phone's time zone decides the athlete's day, as X04/zone and G06/midnight record."
						)
					]
				),
				"MOB05": ([.requirement(table: four, id: "G06")], []),
				"MOB06": ([], []),
				"MOB07": ([closeout("update")], []),
				"MOB08": ([m4("largest-text"), .phone(session: "plan", step: "plan/6")], []),
				"MOB09": (
					[
						test(
							"BillingIdentityTests",
							"creditsExhaustionPreservesSavedConversationAndMemory"),
						test(
							"BillingIdentityTests",
							"outOfCreditsNoticeKeepsItsActionAfterReopeningAndInHistory"),
						proof(
							"BillingIdentityProof", "BillingIdentityProof",
							"testExhaustedCreditsKeepMemoryAndMessagesAndOfferWorkingRoutes"),
					], []
				),
				"MOB10": (
					[
						.requirement(table: four, id: "X02"),
						test("FragmentOrderingTests", "fragmentsExtendTheRealTrailingWindow"),
						test("ChatMailboxTests", "sendsInsideTheWindowJoinOneTurn"),
						test("AcceptTests", "concurrentAcceptsOfOneDraftWriteOneMessage"),
					], []
				),
				"MOB11": ([], []),
				"MOB12": ([.requirement(table: five, id: "X08")], []),
			]

	static let deviceCheckRows: [String: [EvidencePointer]] = [
		"B03.01": [closeout("openrouter-signin")],
		"B03.03": [closeout("openrouter-signin")],
		"B03.04": [closeout("openrouter-recovery")],
		"B05.01": [closeout("language")],
		"B07.05": [closeout("lifecycle")],
		"B08.03": live("reads-failing"),
		"B13.01": live("not-connected", "ftp-not-usable") + [
			.test(
				file:
					"apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachLiveChecks/LiveReadsCheck.swift",
				name: .function("readsTheKeyOwnerThroughTheAppsReadCode"))
		],
		"B13.03": live("review-deep"),
		"B13.04": live("review-brief", "review-default", "review-deep", "review-ambiguous"),
		"B13.05": live("review-close-pair"),
		"B13.06": live("review-brief", "review-default", "review-deep") + [closeout("reads")],
		"B13.07": live("status", "status-with-text", "not-connected", "workout-45-minutes-indoors"),
		"B14.01": live("changed-goal") + [closeout("reads")],
		"B14.02": live("zones-from-ftp"),
		"B14.03": live("designed-workout"),
		"B16.01": [closeout("choices")],
		"G05": [m4("offline-approve")],
		"MOB01": [closeout("lifecycle")],
		"MOB03": [closeout("lifecycle")],
		"MOB02": [m4("offline-approve")],
		"MOB08": [m4("largest-text"), .phone(session: "plan", step: "plan/6")],
	]

	@Test(.timeLimit(.minutes(1)))
	func theFiveDecisionsAdrEightyFiveSettlesAreMetByIt() throws {
		let rows = try Self.committedRows()
		let record = EvidencePointer.record("ADR-0085")
		for id in ["D04", "D11", "D12", "D13"] {
			#expect(rows[id]?.status == .met, "\(id)")
			#expect(rows[id]?.evidence == [record], "\(id)")
		}
		#expect(rows["D15"]?.status == .met)
		#expect(rows["D15"]?.evidence == [record, .criterion(table: Self.six, id: "6.1.9")])
	}

	@Test(.timeLimit(.minutes(1)))
	func crossCuttingAndJourneyRowsAreMetByTheirExistingProofs() throws {
		let rows = try Self.committedRows()
		let first = Self.proof("TutorialProofs", "FirstConversationProof", "testFirstConversation")
		let relaunch = Self.proof(
			"TutorialProofs", "RelaunchKeepsChatProof", "testRelaunchKeepsChat")
		let expected: [String: [EvidencePointer]] = [
			"X03": [
				Self.test("TrainingSnapshotTests", "bothReadsFailingGiveTheFallbackAndNoLines"),
				Self.test(
					"TrainingSnapshotTests", "missedDeadlineCancelsBothReadsAndGivesTheFallback"),
				Self.test(
					"CoachUpgradeTests",
					"anOpenReviewOpensOfflineAsAskTheCoachAgainWithNoControlAndStaysSoOnline"),
				Self.proof("LanguageMatrixProofs", "LanguageMatrixEnSweep", "testFailureNotices"),
				Self.test(
					"BillingIdentityTests", "creditsExhaustionPreservesSavedConversationAndMemory"),
			],
			"G01": [
				first, relaunch,
				Self.test(
					"CoachMemoryRecallTests", "relaunchRecoversCorrectedFactsAndDatedHistory"),
				Self.test(
					"TurnRecoveryTests",
					"theFirstSnapshotAndRetryAfterRelaunchSeeTheSavedWorkOfADeadClaim"),
				Self.proof(
					"RecoveryProofs", "SavedWorkInterruptedProof", "testSavedWorkInterrupted"),
			],
			"G02": [
				Self.test(
					"ActivityReviewEvidenceTests",
					"sevenDayListLeadsToOneActivitysDetailAndThenToItsStreams"),
				Self.test(
					"ActivityReviewEvidenceTests",
					"twoActivitiesWithTheSameDayAndTitleAreListedApartAndEachIsReadAsItself"),
				Self.proof("TutorialProofs", "ReviewProof", "testReview"),
				Self.test(
					"ActivityReviewEvidenceTests",
					"startsShowTheTimeOfDayThatTheThirtyMinuteRuleReadsAndADateOnlyStartShowsTheDate"
				),
				Self.test(
					"ActivityReviewEvidenceTests",
					"detailReadThatFailsAfterAGoodListGivesItsFailureAnswerAndNoActivityData"),
				Self.test(
					"NumbersFollowUpTests",
					"detailReadAfterABriefReviewIsAnsweredAndBringsNoStreamStatistics"),
			],
		]
		for (id, evidence) in expected {
			#expect(rows[id]?.status == .met, "\(id)")
			#expect(rows[id]?.evidence == evidence, "\(id)")
		}
	}

	@Test(.timeLimit(.minutes(1)))
	func everyMobileRowClosesAsListed() throws {
		let root = RetainedTests.repository.path
		let hand = try HandEvidence.load(root: root)
		let sitting = try SittingRecord.load(root: root)
		let mobile = try RetainedTests.committed().requirements.filter { $0.group == .mobile }
		#expect(Set(mobile.map(\.id)) == Set(Self.mobileRows.keys))
		for (id, listed) in Self.mobileRows {
			#expect(hand.evidence[id, default: []] == listed.evidence, "\(id)")
			#expect(hand.differences[id, default: []] == listed.differences, "\(id)")
			#expect(
				hand.waitsOn[id, default: []] == Self.unpassed(listed.evidence, in: sitting),
				"\(id)")
		}
	}

	@Test(.timeLimit(.minutes(1)))
	func everyDeviceCheckRowClosesAsListed() throws {
		let root = RetainedTests.repository.path
		let hand = try HandEvidence.load(root: root)
		let sitting = try SittingRecord.load(root: root)
		for (id, closing) in Self.deviceCheckRows {
			#expect(
				hand.evidence[id, default: []].filter(Self.closesOnTheRealServices) == closing,
				"\(id)")
			#expect(hand.waitsOn[id, default: []] == Self.unpassed(closing, in: sitting), "\(id)")
		}
		let index = try CoverageIndex.load(root: root)
		let languagePassed = sitting.steps["closeout/language"]?.verdict == .pass
		let offlineApprovePassed = sitting.steps["m4/offline-approve"]?.verdict == .pass
		#expect(index.tables[Self.six]?.open.contains("B05.01") == !languagePassed)
		#expect(index.tables[Self.four]?.open.contains("G05") == !offlineApprovePassed)
		let six = try JSONValue.parse(
			String(contentsOfFile: NodePath.join(root, Self.six), encoding: .utf8))
		let planned = try six.member("plan").member("requirements").member("B05.01").elements()
		#expect(planned.compactMap(\.text).contains("10.1.2"))
		let closeout = try PhoneSessionPlan.load(
			path: PhoneSessionPlan.path(root: root, name: "closeout"))
		#expect(closeout.steps.contains { $0.id == "closeout/language" })
		let reads = try #require(closeout.steps.first { $0.id == "closeout/reads" })
		let lines = [
			reads.checks.prefix(2).map(\.look),
			reads.checks.dropFirst(2).map(\.look),
		]
		#expect(
			lines == [
				["the reply to /review, read by VoiceOver", "the reply to \"show numbers\""],
				["the reply to a power-curve question on an athlete with no curve data"],
			])
		#expect(reads.planned == 3)
	}

	@Test(.timeLimit(.minutes(1)))
	func theApprovedOnePhoneAndPasteDeviationsCloseWithoutTheirPhoneSteps() throws {
		let rows = try Self.committedRows()
		let approved = [
			"B04.01": "B04.01/write-timing", "G09": "G09/paste-limits",
			"B02.03": "B02.03/one-phone", "B04.03": "B04.03/one-phone",
			"MOB06": "MOB06/one-phone", "X07": "X07/one-device", "MOB11": "MOB11/one-device",
		]
		for (id, sub) in approved {
			let row = try #require(rows[id], "\(id)")
			#expect(row.status == .deviation, "\(id)")
			#expect(
				row.differences.contains(.agreed(table: Self.six, sub: sub, record: "ADR-0085")),
				"\(id)")
		}
		let steps = ["two-phone", "keychain-proof", "feedback", "second-device-diagnostics"]
		let pointers = steps.map(Self.closeout)
		let waits = steps.map { OpenReason.phone(session: "closeout", step: "closeout/" + $0) }
		for row in rows.values {
			#expect(row.evidence.allSatisfy { !pointers.contains($0) }, "\(row.id)")
			#expect(row.waitsOn.allSatisfy { !waits.contains($0) }, "\(row.id)")
		}
	}

	private static func committedRows() throws -> [String: CloseoutRow] {
		let root = RetainedTests.repository.path
		let section = CloseoutDerivation.section(
			retained: try RetainedTests.committed(), hand: try HandEvidence.load(root: root),
			tables: try CoverageIndex.load(root: root).tables)
		return Dictionary(uniqueKeysWithValues: section.rows.map { ($0.id, $0) })
	}

	private static func closesOnTheRealServices(_ pointer: EvidencePointer) -> Bool {
		switch pointer {
		case .phone, .live: true
		case .test(let file, _): file.hasPrefix(CloseoutChecker.liveChecks + "/")
		case .criterion, .requirement, .record: false
		}
	}

	private static func unpassed(_ pointers: [EvidencePointer], in sitting: SittingRecord)
		-> [OpenReason]
	{
		pointers.compactMap { pointer in
			guard case .phone(let session, let step) = pointer,
				sitting.steps[step]?.verdict != .pass
			else { return nil }
			return .phone(session: session, step: step)
		}
	}

	private static func test(_ suite: String, _ function: String) -> EvidencePointer {
		.test(file: packageTests + suite + ".swift", name: .function(function))
	}

	private static func proof(_ file: String, _ testClass: String, _ method: String)
		-> EvidencePointer
	{
		.test(file: proofs + file + ".swift", name: .method(class: testClass, method: method))
	}

	private static func closeout(_ step: String) -> EvidencePointer {
		.phone(session: "closeout", step: "closeout/" + step)
	}

	private static func m4(_ step: String) -> EvidencePointer {
		.phone(session: "m4", step: "m4/" + step)
	}

	private static func live(_ scenarios: String...) -> [EvidencePointer] {
		scenarios.map { .live(scenario: $0) }
	}
}
