import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@Suite struct Build6833d90fStoreSeed {
	static let question =
		"Give me a 60 minute endurance ride for tomorrow with two 10 minute tempo blocks"
	static let workout = """
		{"date":"1998-06-16","workout":{"name":"Endurance with tempo","steps":[{"type":"warmup","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}},{"type":"set","repeat":2,"interval":{"type":"interval","duration":{"value":10,"unit":"minutes"},"power":{"kind":"watts","low":190,"high":225}},"recovery":{"type":"recovery","duration":{"value":5,"unit":"minutes"},"power":{"kind":"zone","low":1,"high":2}}},{"type":"cooldown","duration":{"value":10,"unit":"minutes"},"power":{"kind":"percent_ftp","low":55,"high":65}}]}}
		"""

	struct Session {
		let log: SwiftDataRecordLog
		let intervals: FakeIntervalsClient
		let transport: FakeModelTransport
		let coach: Coach
	}

	@Test func generate() async throws {
		let destination = try #require(
			ProcessInfo.processInfo.environment["UPGRADE_STORE_DESTINATION"])
		let root = URL(filePath: destination, directoryHint: .isDirectory)
		try await openReview(in: try await session(root.appending(path: "open-review")))
		try await unknownWrite(in: try await session(root.appending(path: "unknown-write")))
		try await completed(in: try await session(root.appending(path: "completed")))
	}

	private func openReview(in session: Session) async throws {
		_ = try await propose(in: session)
		#expect(try await count(.deviceLocal([.pendingProposal]), in: session) == 1)
		#expect(try await count(.synced([.reviewWrite]), in: session) == 0)
	}

	private func unknownWrite(in session: Session) async throws {
		let token = try await propose(in: session)
		session.intervals.loseCalendarSaveAnswerOnce = true
		let outcome = await session.coach.decide(.approve(token), in: .main)
		#expect(outcome.notice?.key == Catalog.reviewWritePending)
		#expect(try await evidence(in: session) == [.notSent, .unknown(.dispatched)])
	}

	private func completed(in session: Session) async throws {
		let applied = await session.coach.decide(
			.approve(try await propose(in: session)), in: .main)
		guard case .applied = applied else {
			Issue.record("the first approval did not apply: \(applied)")
			return
		}
		let token = try await propose(in: session)
		session.intervals.writeFailure = IntervalsError.unreachable(URLError(.timedOut))
		_ = await session.coach.decide(.approve(token), in: .main)
		session.intervals.writeFailure = nil
		let unknown = try #require(await session.coach.currentSnapshot(.main)?.review)
		_ = await session.coach.decide(.checkAgain(unknown.ref), in: .main)
		guard
			case .retryRemainingOrCancel(let cancel) = try #require(
				await session.coach.currentSnapshot(.main)?.review
			).controls
		else {
			Issue.record("the unknown write offered no Cancel")
			return
		}
		#expect(await session.coach.decide(.cancel(cancel), in: .main) == .canceled(kept: []))
		#expect(try await count(.synced([.reviewCancelledUnknown]), in: session) == 1)
		#expect(try await count(.synced([.reviewApplied]), in: session) == 1)
	}

	private func session(_ root: URL) async throws -> Session {
		let log = SwiftDataRecordLog(
			deviceId: DeviceID(rawValue: "build-6833d90f"),
			synced: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.syncedStoreFileName)),
			local: try ModelContainerHandle.withoutCloudKit(
				storeURL: root.appending(path: ModelContainerHandle.localStoreFileName)))
		let intervals = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
		let transport = FakeModelTransport()
		let coach = await makeCoach(
			transport: transport, intervals: intervals, store: log,
			clock: FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana"))
		return Session(log: log, intervals: intervals, transport: transport, coach: coach)
	}

	private func propose(in session: Session) async throws -> ReviewControlToken {
		session.transport.respond = ScriptedReply.sequence([
			.toolCall(name: ToolName.intervalsCreateWorkout.rawValue, arguments: Self.workout),
			.finish(reason: .toolCalls), .text("I've prepared the ride. Confirm to add it."),
			.finish(reason: .stop),
		])
		_ = try await session.coach.sendAndSettle(Self.question)
		let review = try #require(await session.coach.currentSnapshot(.main)?.review)
		#expect(review.cards.count == 1)
		#expect(
			await session.coach.decide(.presented(review.ref), in: .main) == .presentationRecorded)
		return try #require(await session.coach.currentSnapshot(.main)?.review?.token)
	}

	private func count(_ scope: RecordQuery.Scope, in session: Session) async throws -> Int {
		let page = try await session.log.fetch(RecordQuery(scope: scope))
		#expect(page.skipped.isEmpty)
		return page.records.count
	}

	private func evidence(in session: Session) async throws -> [CalendarWriteEvidence] {
		try await session.log.fetch(RecordQuery(scope: .synced([.reviewWrite]))).records
			.compactMap { record in
				guard case .synced(.reviewWrite(let body)) = record.body else { return nil }
				return body.evidence
			}
	}
}
