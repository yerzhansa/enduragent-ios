extension SourceCases {
	static let feedbackClientSource = "\(coachSources)/Support/FeedbackClient.swift"
	static let fakeFeedbackSource = "\(coachFixtures)/FakeFeedbackServer.swift"
	static let liveFeedbackSource =
		"apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachLiveChecks/LiveFeedbackNote.swift"
	static let appServicesSource = "apps/ios/Enduragent/App/AppServices.swift"
	static let harnessSource = "apps/ios/EnduragentUITests/TutorialHarness.swift"
	static let feedbackEndpoint = "let endpoint = \"https://feedback.enduragent.icu/v1/feedback\"\n"
	static let fakeFeedbackClient =
		"let client = FeedbackClient(protocolClasses: [FakeFeedbackProtocol.self])\n"

	static func feedbackFinding(_ file: String, _ condition: String) -> String {
		#""\#(file)" [feedback-fake-only] "\#(condition)""#
	}

	static let feedbackFakeOnly: [SourceCase] = [
		.rejects(
			"rejects the feedback host in an app test",
			["apps/ios/EnduragentTests/X.swift": feedbackEndpoint],
			finding: "feedback-fake-only",
			findingLines: [feedbackFinding("apps/ios/EnduragentTests/X.swift", "host")]),
		.rejects(
			"rejects a feedback client made outside the client and the fake",
			[
				"\(coachTests)/SendTests.swift":
					"let client = FeedbackClient(protocolClasses: [])\n"
					+ "let other: FeedbackClient = .init(protocolClasses: [])\n"
			],
			finding: "feedback-fake-only",
			findingLines: [feedbackFinding("\(coachTests)/SendTests.swift", "client")]),
		.rejects(
			"rejects a fake whose client does not name the fake protocol",
			[fakeFeedbackSource: "let client = FeedbackClient(protocolClasses: [])\n"],
			finding: "feedback-fake-only",
			findingLines: [feedbackFinding(fakeFeedbackSource, "client")]),
		.rejects(
			"rejects the live client outside the support service and the live check",
			[
				"\(coachTests)/LiveTests.swift": "let client = FeedbackClient.live\n",
				"\(coachFixtures)/Services.swift": "let service = make(feedback: .live)\n",
			],
			finding: "feedback-fake-only",
			findingLines: [
				feedbackFinding("\(coachFixtures)/Services.swift", "live"),
				feedbackFinding("\(coachTests)/LiveTests.swift", "live"),
			]),
		.rejects(
			"rejects the device support service outside the app services",
			[
				"apps/ios/Enduragent/Fixtures/FixtureServices.swift":
					"let support = try SupportService.onDevice(app: identity)\n",
				"apps/ios/EnduragentTests/ServiceTests.swift":
					"let ports = make(support: try .onDevice(app: identity))\n",
			],
			finding: "feedback-fake-only",
			findingLines: [
				feedbackFinding("apps/ios/Enduragent/Fixtures/FixtureServices.swift", "onDevice"),
				feedbackFinding("apps/ios/EnduragentTests/ServiceTests.swift", "onDevice"),
			]),
		.rejects(
			"rejects a UI proof that launches the app itself",
			[
				"apps/ios/EnduragentUITests/SupportProofs.swift":
					"let app = XCUIApplication()\napp.launch()\n"
			],
			finding: "feedback-fake-only",
			findingLines: [
				feedbackFinding("apps/ios/EnduragentUITests/SupportProofs.swift", "launch")
			]),
		.accepts(
			"accepts the host in tools sources and each maker in its own file",
			[
				"tools/Sources/X.swift": feedbackEndpoint,
				feedbackClientSource:
					feedbackEndpoint
					+ "static var live: FeedbackClient { FeedbackClient(protocolClasses: []) }\n",
				fakeFeedbackSource: fakeFeedbackClient,
				"\(coachSources)/Support/SupportService.swift":
					"let feedback = FeedbackClient.live\n",
				liveFeedbackSource: "let refusal = run(using: FeedbackClient.live)\n",
				appServicesSource: "let ports = make(support: try .onDevice(app: identity))\n",
				harnessSource: "app.launch()\n",
				"apps/ios/EnduragentPhoneTests/PhoneRun.swift": "app.launch()\n",
				"\(coachSources)/Records/Store.swift":
					"let store = try RecordStore.onDevice(deviceId: id)\n",
				"\(coachTests)/BodyTests.swift": "let body = try FeedbackClient.body(of: note)\n",
			]),
	]
}
