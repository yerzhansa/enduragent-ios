import EnduragentCoachFixtures
import XCTest

@MainActor
final class ReplyFormattingProof: XCTestCase {
	func testFormattedReplyInChatAndHistory() {
		ReplyFormattingScreen.prove(self, dark: false)
	}
}

@MainActor
final class ReplyFormattingDarkProof: XCTestCase {
	func testFormattedReplyInChatAndHistory() {
		ReplyFormattingScreen.prove(self, dark: true)
	}
}

@MainActor
private enum ReplyFormattingScreen {
	static func prove(_ test: XCTestCase, dark: Bool) {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:formatted")
		ReplyProofScreen.scrollToEnd(app)
		TutorialHarness.attach(test, name: "reply-formatted-chat-end", app: app)
		ReplyProofScreen.scrollToHeading(app)
		let chat = ReplyProofScreen.labels(app)
		ReplyProofScreen.assertDocument(app, source: FormattedReplyFixture.source)
		ReplyProofScreen.assertLinks(app)
		let luminance = TutorialHarness.meanLuminance(app.screenshot())
		if dark {
			XCTAssertLessThan(luminance, 0.35)
		} else {
			XCTAssertGreaterThan(luminance, 0.65)
		}
		TutorialHarness.attach(
			test, name: dark ? "reply-chat-long-dark" : "reply-chat-long-light", app: app)
		TutorialHarness.startNewConversation(app)
		ReplyProofScreen.openArchive(app)
		ReplyProofScreen.scrollToHeading(app)
		XCTAssertEqual(ReplyProofScreen.labels(app), chat)
		ReplyProofScreen.assertDocument(app, source: FormattedReplyFixture.source)
		ReplyProofScreen.assertLinks(app)
		TutorialHarness.attach(test, name: "reply-formatted-history-top", app: app)
		ReplyProofScreen.scrollToEnd(app)
		TutorialHarness.attach(test, name: "reply-formatted-history-end", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

@MainActor
final class ReplyStreamingStoppedProof: XCTestCase {
	func testFormattedDeltasStopAndArchiveWithoutChangingThePrefix() {
		let app = XCUIApplication()
		TutorialHarness.launch(app)
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.send(app, "fixture:formatted-then-hang")
		TutorialHarness.wait(TutorialHarness.named(app, "reply.heading"))
		XCTAssertTrue(TutorialHarness.named(app, "chat.working").exists)
		XCTAssertFalse(TutorialHarness.named(app, "reply.code").exists)
		TutorialHarness.attach(self, name: "reply-formatted-streaming-deltas", app: app)
		ReplyProofScreen.waitForPrefix(app)
		let streaming = ReplyProofScreen.labels(app)
		ReplyProofScreen.assertDocument(app, source: FormattedReplyFixture.streamingPrefix)
		let stop = TutorialHarness.named(app, "chat.stop")
		TutorialHarness.wait(stop, until: .hittable)
		let started = ProcessInfo.processInfo.systemUptime
		stop.tap()
		TutorialHarness.wait(
			TutorialHarness.named(app, "chat.working"), until: .absent, within: .probe)
		XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
		TutorialHarness.waitForLabel(app, TutorialHarness.interruptedNothingChanged)
		XCTAssertEqual(ReplyProofScreen.labels(app), streaming)
		ReplyProofScreen.scrollToHeading(app)
		TutorialHarness.attach(self, name: "reply-formatted-stopped-dimmed", app: app)
		TutorialHarness.startNewConversation(app)
		ReplyProofScreen.openArchive(app)
		ReplyProofScreen.assertDocument(app, source: FormattedReplyFixture.streamingPrefix)
		XCTAssertEqual(ReplyProofScreen.labels(app), streaming)
		ReplyProofScreen.scrollToHeading(app)
		TutorialHarness.attach(self, name: "reply-formatted-stopped-history", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}
}

@MainActor
final class ReplyFallbackProof: XCTestCase {
	func testParserFailureShowsTheWholeLiteralReplyWithoutLinks() {
		let app = XCUIApplication()
		TutorialHarness.launch(app, arguments: FixtureArguments(replyParserFault: .fail))
		TutorialHarness.completeOnboarding(app)
		TutorialHarness.exchange(app, "fixture:formatted")
		assertFallback(app)
		TutorialHarness.attach(self, name: "reply-fallback-chat-end", app: app)
		ReplyProofScreen.scrollToFallbackStart(app)
		TutorialHarness.attach(self, name: "reply-fallback-chat-top", app: app)
		TutorialHarness.startNewConversation(app)
		ReplyProofScreen.openArchive(app)
		assertFallback(app)
		TutorialHarness.attach(self, name: "reply-fallback-history", app: app)
		TutorialHarness.closeMenu(app)
		TutorialHarness.assertZeroFixtureRequests(app)
	}

	private func assertFallback(_ app: XCUIApplication) {
		let fallback = TutorialHarness.named(app, "reply.fallback")
		TutorialHarness.wait(fallback)
		XCTAssertEqual(fallback.label, FormattedReplyFixture.source)
		XCTAssertEqual(app.links.count, 0)
		XCTAssertFalse(TutorialHarness.named(app, "reply.heading").exists)
		XCTAssertFalse(TutorialHarness.named(app, "reply.table").exists)
	}
}
