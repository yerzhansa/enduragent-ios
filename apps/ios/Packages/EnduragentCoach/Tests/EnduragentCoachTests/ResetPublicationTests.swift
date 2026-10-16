import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

struct ResetPublicationTests {
	@Test func theOpeningPublishesBeforeTheSavedJobsRereadFinishes() async throws {
		let log = ResetPublicationLog(inner: InMemoryRecordLog())
		defer { log.release() }
		let transport = FakeModelTransport()
		transport.respond = ScriptedReply.sequence(
			[
				.text("Old answer"), .finish(reason: .stop), .text("New answer"),
				.finish(reason: .stop),
			],
			otherwise: transport.respond)
		let coach = await makeCoach(transport: transport, store: log)
		_ = try await coach.sendAndSettle("Old question")
		let admission = try await beforeDeadline(within: .hangGuard, onTimeout: log.release) {
			try await coach.send(draft("/start"), to: .main)
		}
		guard
			case .newConversation(.accepted(let reset)) = try #require(admission)
		else {
			Issue.record("Expected reset admission")
			return
		}
		let next = try #require(try await coach.send(draft("New question"), to: .main).acceptedTurn)
		let rereading = try await beforeDeadline(within: .hangGuard, onTimeout: log.release) {
			var events = log.reached.makeAsyncIterator()
			return await events.next() != nil
		}
		try #require(rereading == true)
		let opened = try await firstSnapshot(
			in: await coach.observe(.main), within: .subject(.seconds(1))
		) {
			$0.opening == .afterNewConversation(reset: reset, memory: .saved)
				&& $0.turns.map(\.id) == [next]
		}
		try #require(
			opened != nil, "The jobs reread must not hold the welcome or the accepted message")
		log.release()
		_ = try #require(await coach.settledState(of: next, in: .main, within: .hangGuard))
	}
}

private struct ResetPublicationLog: RecordLog {
	let inner: HeldFlushReadLog

	init(inner: any RecordLog) { self.inner = HeldFlushReadLog(inner: inner) }
	var deviceId: DeviceID { inner.deviceId }
	var imports: AsyncStream<Void> { inner.imports }
	var reached: AsyncStream<Void> { inner.reached }
	func release() { inner.release() }

	func append(_ batch: [AthleteRecord], locality: RecordLocality) async throws {
		try await inner.append(batch, locality: locality)
		if batch.contains(where: { $0.body.kind == "windowStart" }) {
			inner.holdNextChatFlushRead()
		}
	}

	func latest(locality: RecordLocality, writtenBy: DeviceID) async throws -> RecordCursor? {
		try await inner.latest(locality: locality, writtenBy: writtenBy)
	}

	func fetch(_ query: RecordQuery) async throws -> RecordPage { try await inner.fetch(query) }
}
