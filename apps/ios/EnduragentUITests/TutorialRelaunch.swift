import XCTest

extension TutorialHarness {
	static func relaunchKeepingStore(
		_ app: XCUIApplication, recovery: String = "readable", clock: String? = nil,
		keychain: FixtureKeychainPolicy? = nil, language: String? = nil, locale: String? = nil,
		clearingReadFaults: Bool = false, clearingFeedbackScript: Bool = false,
		trainingDisplay: FixtureTrainingDisplay? = nil, textSize: FixtureTextSize? = nil
	) {
		app.terminate()
		XCTAssertEqual(app.state, .notRunning)
		var arguments = FixtureArguments()
		do {
			try arguments.update(from: app.launchArguments)
		} catch {
			XCTFail("could not read fixture arguments: \(error)")
			return
		}
		arguments.store = .keep
		arguments.recovery = recovery
		if clearingReadFaults {
			arguments.calendarReadFault = nil
			arguments.recordReadFault = nil
			arguments.trainingDisplay = nil
		}
		if let trainingDisplay { arguments.trainingDisplay = trainingDisplay }
		if let textSize { arguments.textSize = textSize }
		if clearingFeedbackScript { arguments.feedback = nil }
		if let clock { arguments.clock = clock }
		if let keychain { arguments.keychain = keychain }
		if let language { arguments.language = language }
		if let locale { arguments.locale = locale }
		launch(app, arguments: arguments)
	}
}
