import XCTest

final class V1PendingReviewSeedProof: XCTestCase {
	func testSeedPendingReviewInTheMainChat() {
		seed(self, TutorialHarness.workout, name: "v1-pending-add")
	}
}

final class V1PendingEditSeedProof: XCTestCase {
	func testSeedPendingEditInTheMainChat() {
		seed(self, "Rename my Thursday ride to Recovery spin", name: "v1-pending-edit")
	}
}

final class V1PendingDeleteSeedProof: XCTestCase {
	func testSeedPendingDeleteInTheMainChat() {
		seed(self, "Delete my Thursday ride", name: "v1-pending-delete")
	}
}

private func seed(_ test: XCTestCase, _ request: String, name: String) {
	let app = XCUIApplication()
	app.launchArguments = [
		"-EnduragentFixture", "first-week", TutorialHarness.storeArgument, "fresh",
		"-AppleLanguages", "(en)", "-AppleLocale", "en_US",
		"-enduragent.onboardingCompleted", "YES",
	]
	app.launch()
	TutorialHarness.send(app, request)
	TutorialHarness.wait(TutorialHarness.named(app, "chat.preview.add"))
	TutorialHarness.attach(test, name: name, app: app)
}
