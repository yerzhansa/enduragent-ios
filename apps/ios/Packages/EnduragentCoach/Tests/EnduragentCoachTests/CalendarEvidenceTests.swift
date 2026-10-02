import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test func aHeldWriteDoesNotBlockStopOrANewSendWithAnOverlappingTool() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .heldAfterCommit }
		let fixture = await fixture(url: url)
		let (_, token) = try await proposal(on: fixture.coach, model: fixture.model)
		let approving = Task { await fixture.coach.decide(.approve(token), in: .main) }
		defer { approving.cancel() }
		try await waitUntil { server.posts.count == 1 }
		await fixture.coach.stop(.main)
		fixture.model.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments:
						#"{"date":"1998-06-14","name":"Replacement","description":"Other sets"}"#
				),
				.finish(reason: .toolCalls), .text("Check the existing write."),
				.finish(reason: .stop),
			], for: .chat, otherwise: fixture.model.respond)
		let settled = try await fixture.coach.sendAndSettle("Replace it", within: .hangGuard)
		#expect(replyText(settled) == "Check the existing write.")
		#expect(
			try await fixture.store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal])))
				.records.count == 1)
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
		approving.cancel()
		_ = await approving.value
	}

	@Test(arguments: [false, true])
	func mismatchedOrDuplicateIdentityStaysUnresolved(duplicate: Bool) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(500) }
		let fixture = await fixture(url: url)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		server.state.withLock { state in
			if duplicate {
				var copy = state.events[0]
				copy["id"] = .number(2)
				state.events.append(copy)
			} else {
				state.events[0]["name"] = .string("Edited elsewhere")
			}
		}
		let review = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(review.ref), in: .main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(pending.controls == .checkAgain(pending.ref))
		#expect(turnNotice(of: try #require(await fixture.coach.state(of: turn)))?.action == nil)
		#expect(server.posts.count == 1)
	}

	@Test func appliedEvidenceSurvivesALaterImportedUnknownObservation() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(504) }
		let store = ImportingRecordLog()
		let fixture = await fixture(url: url, store: store)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		let old = try #require(
			try await store.fetch(RecordQuery(scope: .synced([.reviewWrite]))).records.last)
		let review = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(review.ref), in: .main)
		let confirmed = await fixture.coach.currentSnapshot(.main)
		let snapshots = ImportSnapshots(await fixture.coach.observe(.main))
		try await waitUntil { snapshots.latest != nil }
		let count = snapshots.count
		let later = AthleteRecord(
			ulid: fixedUlid(999), deviceId: old.deviceId,
			hlc: HybridLogicalClock(
				wallMs: old.hlc.wallMs + 1_000, logical: 0, deviceId: old.deviceId),
			timeZone: old.timeZone, civilDate: old.civilDate, cause: old.cause,
			account: old.account, body: old.body)
		try await store.append([later], locality: .synced)
		store.notifyImport()
		try await waitUntil { snapshots.count > count }
		#expect(snapshots.latest == confirmed)
		let reopened = await makeCoach(
			transport: FakeModelTransport(), intervals: fixture.client, store: store)
		#expect(await reopened.currentSnapshot(.main) == confirmed)
		#expect(turnNotice(of: try #require(await fixture.coach.state(of: turn)))?.action == nil)
		#expect(server.posts.count == 1)
	}

	@Test func unknownWriteBlocksAnOverlappingNewProposalAfterStop() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(502) }
		let fixture = await fixture(url: url)
		let (_, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		fixture.model.respond = ScriptedReply.sequence(
			[
				.toolCall(
					name: "intervals_create_strength_workout",
					arguments:
						#"{"date":"1998-06-14","name":"Replacement","description":"Other sets"}"#
				),
				.finish(reason: .toolCalls), .text("Check the existing write."),
				.finish(reason: .stop),
			], for: .chat, otherwise: fixture.model.respond)
		_ = try await fixture.coach.sendAndSettle("Replace that workout")
		#expect(await fixture.coach.currentSnapshot(.main)?.review?.ref.set == pending.ref.set)
		#expect(
			try await fixture.store.fetch(RecordQuery(scope: .deviceLocal([.pendingProposal])))
				.records.count == 1)
		#expect(server.posts.count == 1)
	}
}

extension DurableCalendarWriteTests {
	@Test func repeatingAnApprovalRechecksAnEarlierEmptyRead() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(500) }
		let fixture = await fixture(url: url)
		let (_, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		server.state.withLock { $0.readResponse = .body("[]") }
		let pending = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		_ = await fixture.coach.decide(.checkAgain(pending.ref), in: .main)
		let checked = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		guard case .retryRemainingOrCancel(let repeatToken) = checked.controls else {
			Issue.record("expected repetition after an empty read")
			return
		}
		server.state.withLock {
			$0.readResponse = .success
			$0.response = .success
			$0.events[0]["name"] = .string("Edited elsewhere")
		}
		_ = await fixture.coach.decide(.retryRemaining(repeatToken), in: .main)
		#expect(server.posts.count == 1)
		#expect(server.events.first?["name"]?.stringValue == "Edited elsewhere")
		let unresolved = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(unresolved.controls == .checkAgain(unresolved.ref))
	}
}
