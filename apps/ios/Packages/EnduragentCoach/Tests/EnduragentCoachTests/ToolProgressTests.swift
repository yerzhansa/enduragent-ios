import EnduragentCoachFixtures
import Foundation
import Synchronization
import Testing

@testable import EnduragentCoach

@Suite struct ToolProgressTests {
	let modelClock = HeldClock()
	let readClock = HeldClock()
	let store = InMemoryRecordLog()
	let transport: FakeModelTransport
	let question = "Read my recent rides and prepare an endurance ride for tomorrow."
	let introduction = "Checking your recent rides. "
	let completion = "I've prepared the ride. Confirm to add it."

	init() {
		transport = FakeModelTransport(clock: modelClock)
		transport.respond = ScriptedReply.sequence(
			[
				.text(introduction),
				.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#),
				.finish(reason: .toolCalls),
				.toolCall(
					name: "intervals_create_workout",
					arguments:
						#"{"date":"1998-06-14","workout":{"name":"Endurance","steps":[{"type":"steady","duration":{"value":60,"unit":"minutes"},"power":{"kind":"percent_ftp","low":56,"high":75}}]}}"#
				),
				.finish(reason: .toolCalls),
				.text(completion), .finish(reason: .stop),
			], requestDelay: .seconds(10))
	}

	@Test func workingPersistsAcrossIndependentModelAndToolWaits() async throws {
		let coach = await makeCoach(
			transport: transport, intervals: HeldReadIntervals(clock: readClock), store: store)
		let turn = try #require(try await coach.send(draft(question), to: .main).acceptedTurn)
		try await modelClock.waitUntilHeld(.seconds(10))
		let waitingForModel = try await snapshot(coach)
		#expect(waitingForModel.turns.map(\.id) == [turn])
		#expect(waitingForModel.turns.map(\.athleteText) == [question])
		#expect(waitingForModel.activity == .working(label: Catalog.chatNoticeWorking))
		#expect(waitingForModel.turns.first?.state.isSettled == false)
		#expect(waitingForModel.liveReply?.text.isEmpty == true)
		#expect(readClock.held.isEmpty)

		modelClock.release(.seconds(10))
		try await readClock.waitUntilHeld(.seconds(30))
		let reading = try await snapshot(coach)
		#expect(reading.turns.map(\.id) == [turn])
		#expect(reading.turns.map(\.athleteText) == [question])
		#expect(reading.activity == .working(label: Catalog.chatNoticeWorking))
		guard case .processing(let processing)? = reading.turns.first?.state else {
			Issue.record("The training read must keep the original turn processing")
			return
		}
		#expect(processing.activity == .runningTools([.intervalsFetchActivities]))
		#expect(reading.liveReply?.turn == turn)
		#expect(reading.liveReply?.text == introduction)
		#expect(transport.requestCount == 1)
		#expect(modelClock.held.isEmpty)
		readClock.advance(by: .seconds(15))
		#expect(try await snapshot(coach).activity == .working(label: Catalog.chatNoticeWorking))
		#expect(readClock.held == [.seconds(30)])

		readClock.release(.seconds(30))
		try await modelClock.waitUntilHeld(.seconds(10))
		modelClock.release(.seconds(10))
		try await modelClock.waitUntilHeld(.seconds(10))
		let finishing = try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
				$0.review != nil
			})
		#expect(finishing.activity == .working(label: Catalog.chatNoticeWorking))
		#expect(finishing.turns.first?.state.isSettled == false)
		#expect(finishing.liveReply?.text == introduction)
		modelClock.release(.seconds(10))
		let finished = try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) {
				$0.turns.first?.state.isSettled == true && $0.activity == .idle
			})
		try assertCompleted(finished, turn: turn)
	}

	@Test func closingTheObserverDoesNotCancelToolWork() async throws {
		let host = ImmediateExecutionHost()
		let coach = await makeCoach(
			transport: transport, intervals: HeldReadIntervals(clock: readClock), store: store,
			host: host)
		let seen = Mutex<ChatSnapshot?>(nil)
		let stream = await coach.observe(.main)
		let observer = Task {
			for await snapshot in stream { seen.withLock { $0 = snapshot } }
			return true
		}
		defer { observer.cancel() }
		let turn = try #require(try await coach.send(draft(question), to: .main).acceptedTurn)
		try await modelClock.waitUntilHeld(.seconds(10))
		modelClock.release(.seconds(10))
		try await readClock.waitUntilHeld(.seconds(30))
		try await waitUntil { seen.withLock { $0?.liveReply?.text == introduction } }
		#expect(seen.withLock { $0?.activity } == .working(label: Catalog.chatNoticeWorking))
		observer.cancel()
		try #require(
			try await beforeDeadline(within: .hangGuard) { await observer.value } == true)
		readClock.release(.seconds(30))
		for _ in 0..<2 {
			try await modelClock.waitUntilHeld(.seconds(10))
			modelClock.release(.seconds(10))
		}
		try await waitForRecords(.synced([.turnSettled]), count: 1, in: store)
		try #require(await host.ended(0) != nil)
		let reopened = try await snapshot(coach)
		try assertCompleted(reopened, turn: turn)
		#expect(try await settlements(of: turn, in: store).count == 1)
		#expect(transport.requestCount == 3)
	}

	private func snapshot(_ coach: Coach) async throws -> ChatSnapshot {
		try #require(
			try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) { _ in true
			})
	}

	private func assertCompleted(_ snapshot: ChatSnapshot, turn: TurnID) throws {
		#expect(snapshot.turns.map(\.id) == [turn])
		#expect(snapshot.turns.map(\.athleteText) == [question])
		#expect(replyText(try #require(snapshot.turns.first?.state)) == completion)
		#expect(snapshot.activity == .idle)
		#expect(snapshot.liveReply == nil)
		let review = try #require(snapshot.review)
		#expect(review.ref.chat == .main)
		#expect(
			review.cards.map { $0.name.sentence(in: displayLocale()) } == ["Endurance"])
		#expect(review.cards.map(\.date) == ["1998-06-14"])
		#expect(review.totals.additions == 1)
	}
}
