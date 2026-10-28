import ToolSupport

extension SourceChecker {
	static let uiTestSwift = #"^apps\/ios\/EnduragentUITests\/.*\.swift$"#
	static let feedbackHost = #"feedback\.enduragent\.icu"#
	static let feedbackClientFile =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Support/FeedbackClient.swift"
	static let fakeFeedbackFile =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoachFixtures/FakeFeedbackServer.swift"
	static let supportServiceFile =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Support/SupportService.swift"
	static let liveFeedbackFile =
		"apps/ios/Packages/EnduragentCoach/Tests/EnduragentCoachLiveChecks/LiveFeedbackNote.swift"
	static let appServicesFile = "apps/ios/Enduragent/App/AppServices.swift"
	static let tutorialHarnessFile = "apps/ios/EnduragentUITests/TutorialHarness.swift"
	static let feedbackClientMade =
		#"\bFeedbackClient\s*(?:\.\s*init\s*)?\(|\.\s*init\s*\(\s*protocolClasses\s*:"#
	static let fakeFeedbackClientMade =
		#"\bFeedbackClient\s*\(\s*protocolClasses\s*:\s*\[\s*FakeFeedbackProtocol\s*\.\s*self\s*\]\s*\)"#
	static let liveFeedbackClient = #"\bFeedbackClient\s*\.\s*live\b|\bfeedback\s*:\s*\.\s*live\b"#
	static let deviceSupportService =
		#"\bSupportService\s*\.\s*onDevice\s*\(|(?:^|[^\w)\]?!])\.\s*onDevice\s*\(\s*app\s*:"#
	static let proofLaunch = #"\.\s*launch\s*\(\s*\)"#

	func checkFeedbackFakeOnly(_ source: SourceFile) throws {
		let file = source.file
		guard try patterns.test(Self.iosSwiftSource, file) else { return }
		let code = try patterns.withoutStrings(source.text)
		if try !file.hasSameUnits(as: Self.feedbackClientFile)
			&& patterns.test(Self.feedbackHost, source.text, ignoringCase: true)
		{
			try findings.report(file, "feedback-fake-only", key: "host")
		}
		if try madeFeedbackClientOutsideItsMakers(file, code) {
			try findings.report(file, "feedback-fake-only", key: "client")
		}
		if try !file.hasSameUnits(as: Self.supportServiceFile)
			&& !file.hasSameUnits(as: Self.liveFeedbackFile)
			&& patterns.test(Self.liveFeedbackClient, code)
		{
			try findings.report(file, "feedback-fake-only", key: "live")
		}
		if try !file.hasSameUnits(as: Self.appServicesFile)
			&& patterns.test(Self.deviceSupportService, code)
		{
			try findings.report(file, "feedback-fake-only", key: "onDevice")
		}
		if try patterns.test(Self.uiTestSwift, file)
			&& !file.hasSameUnits(as: Self.tutorialHarnessFile)
			&& patterns.test(Self.proofLaunch, code)
		{
			try findings.report(file, "feedback-fake-only", key: "launch")
		}
	}

	private func madeFeedbackClientOutsideItsMakers(_ file: String, _ code: String) throws -> Bool {
		if file.hasSameUnits(as: Self.feedbackClientFile) { return false }
		let made = try patterns.matchAll(Self.feedbackClientMade, code).count
		guard file.hasSameUnits(as: Self.fakeFeedbackFile) else { return made > 0 }
		return made != (try patterns.matchAll(Self.fakeFeedbackClientMade, code).count)
	}
}
