import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite(.timeLimit(.minutes(1))) struct ChoicesInConversationTests {
	let transport = FakeModelTransport()
	let records = InMemoryRecordLog()
	let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let offer = """
		1. Build endurance. Add easy riding time. This builds stamina with less fatigue. Recommended.
		2. Build speed. Add short hard intervals. This improves speed with more recovery needed.
		"""

	@Test func numberAndLabelKeepWorkoutReviewPendingUntilExplicitApproval() async throws {
		let offer = offer
		transport.respond = ScriptedReply.sequence([
			.toolCall(
				name: "intervals_create_workout",
				arguments:
					#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":45,"unit":"minutes"}}]}}"#
			),
			.finish(reason: .toolCalls), .text(offer), .finish(reason: .stop),
			.text("We can build endurance without saving a plan or adding the ride."),
			.finish(reason: .stop),
			.text("Build speed is the direction; the ride still awaits its separate approval."),
			.finish(reason: .stop),
		])
		let coach = await makeCoach(transport: transport, intervals: intervals, store: records)
		let turn = try #require(
			try await coach.send(draft("Prepare a ride and offer planning directions."), to: .main)
				.acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == offer)
		let review = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(await coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		let token = try #require(await coach.currentSnapshot(.main)?.review?.token)

		for (answer, reply) in [
			("1", "We can build endurance without saving a plan or adding the ride."),
			(
				"I choose Build speed.",
				"Build speed is the direction; the ride still awaits its separate approval."
			),
		] {
			let selected = try #require(try await coach.send(draft(answer), to: .main).acceptedTurn)
			#expect(
				replyText(try #require(await coach.settledState(of: selected, in: .main))) == reply)
			#expect(await coach.currentSnapshot(.main)?.review?.token == token)
			#expect(intervals.calls.filter(\.isWrite).isEmpty)
			#expect(
				try await records.fetch(
					RecordQuery(scope: .deviceLocal([.planRevision, .planningCommand]))
				).records.isEmpty)
			#expect(
				try await records.fetch(RecordQuery(scope: .synced([.reviewWrite]))).records.isEmpty
			)
			let request = try #require(sent(.chatAttempt, by: transport).last)
			#expect(request.messages.contains { $0.role == .assistant && $0.content == offer })
			#expect(request.messages.last?.role == .user)
			#expect(request.messages.last?.content.hasPrefix(answer + "\nCurrent time:") == true)
		}
		let last = try #require(sent(.chatAttempt, by: transport).last)
		#expect(last.messages.contains { $0.role == .user && $0.unstampedContent == "1" })
		#expect(
			last.messages.contains {
				$0.role == .assistant
					&& $0.content
						== "We can build endurance without saving a plan or adding the ride."
			})

		#expect(
			await coach.decide(.approve(token), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(
			intervals.calls.filter(\.isWrite) == [
				.createEvent(date: "1998-06-14", externalId: "cycling-coach:1998-06-14:endurance")
			])
		#expect(await coach.currentSnapshot(.main)?.review == nil)
		let writes = try await records.fetch(RecordQuery(scope: .synced([.reviewWrite]))).records
		guard case .synced(.reviewWrite(let applied)) = writes.last?.body else {
			Issue.record("Expected durable calendar approval evidence.")
			return
		}
		#expect(applied.evidence == .applied(eventID: 1))
		#expect(
			try await records.fetch(
				RecordQuery(scope: .deviceLocal([.planRevision, .planningCommand]))
			)
			.records.isEmpty)
	}

	@Test func startAfterUnansweredChoiceArchivesItAndStartsNewConversation() async throws {
		transport.respond = ScriptedReply.sequence([
			.text(offer), .finish(reason: .stop),
			.text("Let's discuss your new question."), .finish(reason: .stop),
		])
		transport.respond = ScriptedReply.sequence(
			[.finish(reason: .stop)], for: .flush, otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, intervals: intervals, store: records)
		let turn = try #require(
			try await coach.send(draft("Offer planning directions."), to: .main).acceptedTurn)
		#expect(replyText(try #require(await coach.settledState(of: turn, in: .main))) == offer)

		#expect(
			try await coach.send(draft("/start"), to: .main)
				== .newConversation(.started(memory: .saved)))
		let snapshot = try #require(await coach.currentSnapshot(.main))
		#expect(snapshot.turns.isEmpty)
		#expect(snapshot.opening == .afterNewConversation(memorySaved: true))
		let archive = try #require(try await coach.history().first?.id)
		let archived = try #require(try await coach.archivedConversation(archive))
		#expect(archived.reason == .newConversation)
		#expect(archived.turns.map(\.id) == [turn])
		#expect(replyText(try #require(archived.turns.first?.state)) == offer)

		let next = try #require(
			try await coach.send(draft("A new question."), to: .main).acceptedTurn)
		#expect(
			replyText(try #require(await coach.settledState(of: next, in: .main)))
				== "Let's discuss your new question.")
		let request = try #require(sent(.chatAttempt, by: transport).last)
		#expect(request.messages.map(\.role) == [.system, .user])
		#expect(request.messages.last?.content.hasPrefix("A new question.\nCurrent time:") == true)
		#expect(intervals.calls.filter(\.isWrite).isEmpty)
	}
}
