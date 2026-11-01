#if DEBUG
	import Foundation

	public struct RecordSyncProbe: Sendable {
		private static let sampleChat: ChatID = "debug-sample"

		private let ledger: Ledger
		private let calendar: AthleteCalendar

		package init(ledger: Ledger, clock: any Clock) {
			self.ledger = ledger
			self.calendar = AthleteCalendar(clock: clock)
		}

		public var deviceId: DeviceID {
			ledger.deviceId
		}

		public func snapshot() async throws -> RecordSyncSnapshot {
			let (counts, skipped) = try Self.counts(await ledger.census())
			let synced = try await ledger.read(RecordQuery(scope: .everySynced))
			let local = try await ledger.read(RecordQuery(scope: .everyDeviceLocal))
			let records = (synced.records + local.records).sorted { $0.hlc < $1.hlc }
			return RecordSyncSnapshot(
				deviceId: ledger.deviceId,
				newestHLC: records.last.map { hlcText($0.hlc) } ?? "",
				counts: counts,
				rows: records.map { record in
					RecordSyncRow(
						id: record.ulid.rawValue,
						kind: record.body.kind,
						detail: detail(record.body),
						deviceId: record.deviceId.rawValue,
						hlc: hlcText(record.hlc),
						account: record.account.storedValue
					)
				},
				skipped: skipped
			)
		}

		private static func counts(_ census: RecordCensus) throws(LedgerFailure)
			-> (counts: [RecordSyncCount], skipped: Int)
		{
			switch census {
			case .unavailable(let failure):
				throw failure
			case .counted(let synced, let local, let legacy, let skipped):
				var counts: [String: Int] = [:]
				counts.merge(synced.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: +)
				counts.merge(local.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: +)
				counts.merge(legacy.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: +)
				return (
					counts.sorted { $0.key < $1.key }.map {
						RecordSyncCount(kind: $0.key, count: $0.value)
					}, skipped
				)
			}
		}

		public func appendSyncedSamples() async throws {
			let stamp = await sampleStamp()
			let bodies = (1...3).map { index in
				SyncedRecordBody.provenance(
					ProvenanceBody(
						key: "debug-sample:\(stamp.attempt.ulid.rawValue):\(index)",
						garmin: false,
						nonGarmin: false,
						unknown: false,
						contentSha256: sha256Hex("debug-sample:\(index)")
					)
				)
			}
			_ = try await ledger.commit(synced: bodies, stamp: stamp)
		}

		public func appendLocalSample() async throws {
			let stamp = await sampleStamp()
			_ = try await ledger.commit(
				local: [
					.replyObserved(
						ReplyObservedBody(
							chatId: Self.sampleChat, turn: TurnID(ulid: stamp.attempt.ulid),
							attempt: stamp.attempt))
				],
				stamp: stamp
			)
		}

		private func sampleStamp() async -> OperationStamp {
			let sample = await ledger.nextULID()
			let attempt = await ledger.nextULID()
			return OperationStamp(
				operation: .debugSample(DebugSampleID(ulid: sample)),
				attempt: AttemptID(ulid: attempt),
				binding: ActionBinding(account: .unconnected, zone: calendar.deviceZone)
			)
		}

		private func detail(_ body: RecordBody) -> String {
			if case .deviceLocal(.replyObserved(let observed)) = body,
				observed.chatId == Self.sampleChat
			{
				return "replyObserved"
			}
			if case .deviceLocal(.turnClaim(let claim)) = body {
				return claim.lease.rawValue
			}
			guard case .synced(.turnSettled(let settled)) = body else { return "" }
			switch settled.settlement {
			case .replied:
				return "replied"
			case .savedWork(let outcome, _):
				return "savedWork \(outcome.rawValue)"
			case .failed:
				return "failed"
			case .interrupted(_, let cause, _):
				return "interrupted \(cause.rawValue)"
			}
		}

		private func hlcText(_ hlc: HybridLogicalClock) -> String {
			"\(hlc.wallMs).\(hlc.logical)@\(hlc.deviceId.rawValue)"
		}
	}

	public struct RecordSyncSnapshot: Sendable, Equatable {
		public let deviceId: DeviceID
		public let newestHLC: String
		public let counts: [RecordSyncCount]
		public let rows: [RecordSyncRow]
		public let skipped: Int
	}

	public struct RecordSyncCount: Sendable, Equatable, Identifiable {
		public var id: String { kind }
		public let kind: String
		public let count: Int
	}

	public struct RecordSyncRow: Sendable, Equatable, Identifiable {
		public let id: String
		public let kind: String
		public let detail: String
		public let deviceId: String
		public let hlc: String
		public let account: String
	}
#endif
