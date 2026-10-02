import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import SwiftUI
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func formattedDirectiveRendersTheCompleteReplyAndArchivesIt() async throws {
		let services = try services()
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:formatted"
		await model.send()
		let turn = try await settledTurn(model)
		let source = try #require(replyText(turn.state))
		#expect(source == FormattedReplyFixture.source)
		#expect(services.replyParser.document(source) == ReplyParser.foundation.document(source))
		await model.newConversation()
		try await until { model.chat?.turns.isEmpty == true }
		await model.loadHistory()
		guard case .loaded(let history) = model.history else {
			Issue.record("History did not load")
			return
		}
		let ref = try #require(history.first?.id)
		guard case .loaded(let archive) = await model.loadArchivedConversation(ref) else {
			Issue.record("Archived conversation did not load")
			return
		}
		#expect(replyText(try #require(archive.turns.first?.state)) == source)
	}

	@Test func formattedDeltasAndStoppedPartialUseTheSameDocument() async throws {
		let services = try services()
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:formatted-then-hang"
		await model.send()
		try await until {
			model.chat?.liveReply?.text == FormattedReplyFixture.streamingPrefix
		}
		let live = try #require(model.chat?.liveReply?.text)
		#expect(services.replyParser.document(live) == ReplyParser.foundation.document(live))
		await model.stop()
		let turn = try await settledTurn(model)
		guard case .interrupted(let interrupted) = turn.state else {
			Issue.record("Stop did not interrupt the formatted turn")
			return
		}
		#expect(interrupted.partial == live)
		#expect(
			services.replyParser.document(interrupted.partial).accessibilityText.hasPrefix(
				"Next week at a glance"))
	}

	@Test func launchFaultFallsBackToTheWholeActualCoachReply() async throws {
		var configured = launch
		configured.replyParserFault = .fail
		let services = try fixtureServices(configured, defaults: defaults)
		let model = model(services)
		await model.agreeAndStartChatting()
		model.draft.text = "fixture:formatted"
		await model.send()
		let source = try #require(replyText(try await settledTurn(model).state))
		#expect(
			services.replyParser.document(source) == .plainText(source: source, failure: .injected))
		#expect(
			try self.services().replyParser.document(source)
				== ReplyParser.foundation.document(source))
	}
}

@MainActor
@Suite struct ReplyInlineRenderingTests {
	@Test func drawingKeepsStylesAndOnlyValidatedLinks() throws {
		let source =
			"**bold** *italic* ~~strike~~ `watts` [web](https://example.com) [call](tel:+15550100)"
		guard case .blocks(let blocks) = ReplyParser.foundation.document(source),
			case .paragraph(let runs) = blocks.first
		else {
			Issue.record("Expected the formatted paragraph")
			return
		}
		let rendered = ReplyInlineView.attributed(runs)
		#expect(String(rendered.characters) == "bold italic strike watts web [call](tel:+15550100)")
		#expect(rendered.runs.contains { $0.font == .body.bold() })
		#expect(rendered.runs.contains { $0.font == .body.italic() })
		#expect(rendered.runs.contains { $0.strikethroughStyle == .single })
		#expect(rendered.runs.contains { $0.font == .body.monospaced() })
		#expect(rendered.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com"])
	}

	@Test func drawingNeverReinterpretsLiteralMarkup() {
		let source = "**literal** <script>text</script> [unsafe](custom://host)"
		let rendered = ReplyInlineView.attributed([.literal(source)])
		#expect(String(rendered.characters) == source)
		#expect(rendered.runs.allSatisfy { $0.link == nil && $0.font == .body })
	}
}
