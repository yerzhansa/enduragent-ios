import EnduragentCoach
import Foundation
import Synchronization

public final class NativeKeychainProof: Sendable {
	public static let service = "icu.enduragent.ios.native-persistence-proof"
	public static let syntheticKey = "fixture-native-training-secret"
	private let attempts = Mutex<[NativeKeychainAttempt]>([])
	private let bindings = Mutex<[BindingReceipt]>([])

	public init() {}

	public func store() -> ICloudKeychainStore {
		ICloudKeychainStore(nativeService: Self.service) { [self] attempt in
			attempts.withLock { $0.append(attempt) }
		}
	}

	public func bind(_ credential: IntervalsCredential, selection: AthleteSelection) {
		bindings.withLock {
			$0.append(
				BindingReceipt(
					credentialMatches: FixtureTrainingPeer.Key.allCases.contains {
						credential == .apiKey($0.secret)
					},
					keyOwner: selection == .keyOwner))
		}
	}

	#if DEBUG
		public func report(
			coach: Coach, records: RecordStore, intervals: FakeIntervalsClient, buildVersion: String
		)
			async throws -> String
		{
			let synced = try await records.log.fetch(RecordQuery(scope: .everySynced))
			let local = try await records.log.fetch(RecordQuery(scope: .everyDeviceLocal))
			let allRecords = synced.records + local.records
			let bodies = allRecords.map { String(reflecting: $0.body) }
			let snapshot = try await coach.recordSyncProbe().snapshot()
			let secrets = FixtureTrainingPeer.Key.allCases.map(\.secret) + ["fixture-credits-key"]
			let report = Receipt(
				service: Self.service, buildVersion: buildVersion,
				attempts: attempts.withLock { $0 },
				bindings: bindings.withLock { $0 }, athleteID: intervals.athleteId,
				profileReads: intervals.profileReadCount,
				wellnessReads: intervals.wellnessReadCount,
				calendarReads: intervals.calls.filter {
					if case .events = $0 { return true }
					return false
				}.count,
				recordCount: allRecords.count,
				turnAccounts: snapshot.rows.filter { $0.kind == "turnClaim" }.map(\.account),
				recordsContainSecret: bodies.contains { body in
					secrets.contains { body.contains($0) }
				},
				diagnosticsContainSecret: secrets.contains {
					String(reflecting: coach.diagnostics.entries).contains($0)
				})
			return String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
		}
	#endif

	private struct BindingReceipt: Codable, Sendable {
		let credentialMatches: Bool
		let keyOwner: Bool
	}

	private struct Receipt: Encodable {
		let service: String
		let buildVersion: String
		let attempts: [NativeKeychainAttempt]
		let bindings: [BindingReceipt]
		let athleteID: String
		let profileReads: Int
		let wellnessReads: Int
		let calendarReads: Int
		let recordCount: Int
		let turnAccounts: [String]
		let recordsContainSecret: Bool
		let diagnosticsContainSecret: Bool
	}
}
