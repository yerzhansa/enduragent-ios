import EnduragentCoach
import Foundation
import Synchronization

public final class FixtureTrainingPeer: Sendable {
	public enum Key: String, CaseIterable, Sendable {
		case athleteA
		case athleteB
		case rotatedA
		case rejected
		case unavailable

		public var secret: String {
			switch self {
			case .athleteA: NativeKeychainProof.syntheticKey
			case .athleteB: "other-athlete"
			case .rotatedA: "fixture-rotated-training-key"
			case .rejected: "fixture-rejected-training-key"
			case .unavailable: "fixture-unavailable-training-key"
			}
		}
	}

	private let secrets: any SecretStore
	public let athleteA: FakeIntervalsClient
	public let athleteB: FakeIntervalsClient
	private let rejected = FakeIntervalsClient(athleteName: "Unavailable", ftp: 0)
	private let unavailable = FakeIntervalsClient(athleteName: "Unavailable", ftp: 0)
	private let heldProfile = Mutex<FakeIntervalsReadGate?>(nil)

	public init(secrets: any SecretStore, athleteA: FakeIntervalsClient) {
		self.secrets = secrets
		self.athleteA = athleteA
		self.athleteB = FakeIntervalsClient(athleteName: "Bo Lind", ftp: 240, athleteId: "i2002")
		athleteB.wellness = [WellnessDay(date: "1998-06-15", fitness: 35, fatigue: 40, form: -5)]
		rejected.setProfileOutcome(
			.failure(IntervalsError(code: "http", details: "Rejected fixture key", status: 401)))
		unavailable.setProfileOutcome(.failure(URLError(.notConnectedToInternet)))
	}

	public func client(for credential: IntervalsCredential) -> FakeIntervalsClient {
		switch credential {
		case .apiKey(Key.athleteB.secret): athleteB
		case .apiKey(Key.rejected.secret): rejected
		case .apiKey(Key.unavailable.secret): unavailable
		default: athleteA
		}
	}

	public func replace(_ key: Key) throws {
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: ConnectionID(), credential: .apiKey(key.secret), selection: .keyOwner,
				resolvedAthlete: nil))
	}

	public func delete() throws {
		try secrets.delete(.intervalsConnection)
	}

	public func holdNextProfile() {
		heldProfile.withLock { $0 = athleteA.holdNextProfileRead() }
	}

	public func releaseProfile() async {
		let gate = heldProfile.withLock { held in
			defer { held = nil }
			return held
		}
		await gate?.release()
	}

	public func report() throws -> String {
		let current = try secrets.intervalsConnection()
		let key = Key.allCases.first { current?.credential == .apiKey($0.secret) }
		let receipt = Receipt(
			key: current == nil ? "deleted" : key?.rawValue ?? "athleteA",
			athleteAProfileReads: athleteA.profileReadCount,
			athleteBProfileReads: athleteB.profileReadCount,
			athleteAWrites: writes(athleteA), athleteBWrites: writes(athleteB),
			athleteACalendarCalls: calendarCalls(athleteA),
			athleteBCalendarCalls: calendarCalls(athleteB))
		return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
	}

	private func writes(_ client: FakeIntervalsClient) -> Int {
		client.calls.filter {
			switch $0 {
			case .createEvent, .updateEvent, .deleteEvent: true
			default: false
			}
		}.count
	}

	private func calendarCalls(_ client: FakeIntervalsClient) -> Int {
		client.calls.filter {
			switch $0 {
			case .events, .createEvent, .updateEvent, .deleteEvent: true
			default: false
			}
		}.count
	}

	private struct Receipt: Encodable {
		let key: String
		let athleteAProfileReads: Int
		let athleteBProfileReads: Int
		let athleteAWrites: Int
		let athleteBWrites: Int
		let athleteACalendarCalls: Int
		let athleteBCalendarCalls: Int
	}
}
