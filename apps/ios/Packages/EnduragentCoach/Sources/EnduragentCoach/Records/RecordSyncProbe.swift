#if DEBUG
	import Foundation

	public struct RecordSyncProbe: Sendable {
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
			let synced = try await ledger.read(RecordQuery(scope: .everySynced))
			let local = try await ledger.read(RecordQuery(scope: .everyDeviceLocal))
			let records = (synced.records + local.records).sorted { $0.hlc < $1.hlc }
			var counts: [String: Int] = [:]
			for record in records {
				counts[record.body.kind, default: 0] += 1
			}
			return RecordSyncSnapshot(
				deviceId: ledger.deviceId,
				newestHLC: records.last.map { hlcText($0.hlc) } ?? "",
				counts: counts.sorted { $0.key < $1.key }.map {
					RecordSyncCount(kind: $0.key, count: $0.value)
				},
				rows: records.map { record in
					RecordSyncRow(
						id: record.ulid.rawValue,
						kind: record.body.kind,
						deviceId: record.deviceId.rawValue,
						hlc: hlcText(record.hlc)
					)
				},
				skipped: synced.skipped.count + local.skipped.count
			)
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
					.proposalCleared(
						ProposalClearedBody(chatId: .main, nonce: Nonce(), reason: .expired))
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
		public let deviceId: String
		public let hlc: String
	}
#endif
