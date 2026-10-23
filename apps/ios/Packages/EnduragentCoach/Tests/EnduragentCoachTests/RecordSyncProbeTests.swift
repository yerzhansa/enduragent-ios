import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct RecordSyncProbeTests {
		let phoneA = DeviceID(rawValue: "phone-a")

		@Test(arguments: RecordLogKind.allCases)
		func localSampleIsAReplyObservedRowOnTheDebugSampleChat(kind: RecordLogKind)
			async throws
		{
			let log = try makeRecordLog(kind, deviceId: phoneA)
			let coach = await makeCoach(transport: FakeModelTransport(), store: log)
			let probe = coach.recordSyncProbe()

			try await probe.appendLocalSample()

			let written = try await log.fetch(RecordQuery(scope: .deviceLocal([.replyObserved])))
			#expect(written.skipped.isEmpty)
			let sample = try #require(written.records.only)
			guard case .deviceLocal(.replyObserved(let body)) = sample.body,
				case .operation(.debugSample, let attempt) = sample.cause
			else {
				Issue.record("expected a debug-sample replyObserved row, got \(sample)")
				return
			}
			#expect(body.chatId == "debug-sample")
			#expect(body.attempt == attempt)
			#expect(sample.account == .unconnected)
			let snapshot = try await probe.snapshot()
			#expect(snapshot.skipped == 0)
			#expect(snapshot.counts.contains(RecordSyncCount(kind: "replyObserved", count: 1)))
			let row = try #require(snapshot.rows.first { $0.id == sample.ulid.rawValue })
			#expect(row.kind == "replyObserved")
			#expect(row.detail == "replyObserved")
			#expect(row.deviceId == phoneA.rawValue)
			#expect(row.account == "unconnected")
		}
	}
}

extension Array {
	fileprivate var only: Element? {
		count == 1 ? first : nil
	}
}
