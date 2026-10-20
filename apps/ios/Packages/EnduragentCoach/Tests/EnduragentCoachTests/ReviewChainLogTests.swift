import EnduragentCoachFixtures
import Foundation
import SwiftData
import Testing

@testable import EnduragentCoach

enum SharedChainStore: String, CaseIterable, CustomTestStringConvertible {
	case oneSwiftDataLog
	case twoSwiftDataLogsOnOneDirectory
	case twoFixtureStoresOnOneDirectory
	case oneInMemoryLog

	var testDescription: String { rawValue }

	func logs(deviceId: DeviceID) throws -> (any ReviewChainLog, any ReviewChainLog) {
		switch self {
		case .oneSwiftDataLog:
			let log = try SwiftDataSuites.makeSwiftDataLog(deviceId: deviceId)
			return (log, log)
		case .twoSwiftDataLogsOnOneDirectory:
			let directory = try TestTemporaryFolders.make()
			let synced = try ModelContainerHandle.withoutCloudKit(
				storeURL: directory.appending(path: ModelContainerHandle.syncedStoreFileName))
			let open = {
				SwiftDataRecordLog(
					deviceId: deviceId, synced: synced,
					local: try ModelContainerHandle.deviceLocal(directory: directory))
			}
			return (try open(), try open())
		case .twoFixtureStoresOnOneDirectory:
			let directory = try TestTemporaryFolders.make()
			let open = {
				try FixtureRecordStore(directory: directory, deviceId: deviceId).faults.log
			}
			return (try open(), try open())
		case .oneInMemoryLog:
			let log = InMemoryRecordLog(deviceId: deviceId)
			return (log, log)
		}
	}
}

extension SwiftDataSuites {
	@Suite(.timeLimit(.minutes(2))) struct ReviewChainLogTests {
		let phone = DeviceID(rawValue: "chain-phone")
		let clock = FixedClock(now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")

		func ledger(_ log: any ReviewChainLog, clock: FixedClock? = nil) -> Ledger {
			let clock = clock ?? self.clock
			return Ledger(log: log, clock: clock, diagnostics: DiagnosticsLog(clock: clock))
		}

		func stamp(_ review: WorkoutReview) -> OperationStamp {
			testStamp(operation: .workoutReview(review.id, review.revision))
		}

		func commit(_ review: WorkoutReview, on ledger: Ledger, after head: RecordHead) async
			-> Result<AthleteRecord, TransitionFailure>
		{
			do {
				return .success(
					try await ledger.commit(review: review, stamp: stamp(review), after: head))
			} catch {
				return .failure(error)
			}
		}

		@Test(arguments: SharedChainStore.allCases)
		func twoWritersAfterOneHeadLandExactlyOneRecord(_ store: SharedChainStore) async throws {
			let (first, second) = try store.logs(deviceId: phone)
			let writers = (ledger(first), ledger(second))
			let approval = try reviewFixture("workout-review-approval")
			let claimed = try approval.claimed(Claim(id: claimID(1), action: .approve))
			let rounds = 200
			for round in 0..<rounds {
				let (head, _) = try await writers.0.reviewHead(chat: .main)
				let (seen, _) = try await writers.1.reviewHead(chat: .main)
				#expect(seen == head)
				async let one = commit(approval, on: writers.0, after: head)
				async let other = commit(claimed, on: writers.1, after: head)
				let results = await [one, other]
				let landed = results.compactMap(\.success)
				try #require(landed.count == 1, "round \(round): \(results)")
				let winner = try #require(landed.first)
				#expect(
					results.compactMap(\.failure) == [.headMoved(.record(winner.ulid))],
					"round \(round)")
				let (after, _) = try await writers.0.reviewHead(chat: .main)
				#expect(after == .record(winner.ulid))
			}
			let chain = try await writers.1.read(
				RecordQuery(scope: .deviceLocal([.workoutReview]), chatId: .main))
			#expect(chain.records.count == rounds)
		}

		@Test func aFailedSaveLeavesTheHeadAndIsAStorageFailure() async throws {
			let faults = FaultInjectingRecordLog(wrapping: try makeSwiftDataLog(deviceId: phone))
			let writer = ledger(faults)
			let approval = try reviewFixture("workout-review-approval")
			let claimed = try approval.claimed(Claim(id: claimID(1), action: .approve))
			let saved = try await writer.commit(
				review: approval, stamp: stamp(approval), after: .empty)

			faults.failNextAppend = true
			let failed = await commit(claimed, on: writer, after: .record(saved.ulid))

			#expect(failed.failure == .storage(.rejectedBatch))
			let (head, review) = try await writer.reviewHead(chat: .main)
			#expect(head == .record(saved.ulid))
			#expect(review == approval)
			let retried = await commit(claimed, on: writer, after: .record(saved.ulid))
			let landed = try #require(retried.success)
			#expect(try await writer.reviewHead(chat: .main) == (.record(landed.ulid), claimed))
		}

		@Test func theHeadIsTheChatsNewestReviewAndTheNextRecordSortsAfterIt() async throws {
			let log = try makeSwiftDataLog(deviceId: phone)
			let reader = ledger(log)
			#expect(try await reader.reviewHead(chat: .main) == (.empty, nil))
			let later = FixedClock(now: "1998-06-13T09:00:00+02:00", timeZone: "Europe/Amsterdam")
			let writer = ledger(log, clock: later)
			let approval = try reviewFixture("workout-review-approval")
			let claimed = try approval.claimed(Claim(id: claimID(1), action: .approve))
			let other = try #require(ChatID(rawValue: "other"))
			let older = try await writer.commit(
				review: approval, stamp: stamp(approval), after: .empty)
			let newest = try await writer.commit(
				review: claimed, stamp: stamp(claimed), after: .record(older.ulid))
			let elsewhere = try WorkoutReviewPayload.decode(
				Data(
					String(decoding: try fixtureData("workout-review-approval"), as: UTF8.self)
						.replacingOccurrences(of: "\"chat\": \"main\"", with: "\"chat\": \"other\"")
						.utf8))
			#expect(elsewhere.chat == other)
			let elsewhereRecord = try await writer.commit(
				review: elsewhere, stamp: stamp(elsewhere), after: .empty)
			try await writer.markPreparing(
				chat: .main, turn: TurnID(ulid: fixedUlid(7)),
				attempt: AttemptID(ulid: fixedUlid(8)),
				stamp: stamp(approval))

			let (head, review) = try await reader.reviewHead(chat: .main)

			#expect(head == .record(newest.ulid))
			#expect(review == claimed)
			let next = try await reader.commit(
				review: approval, stamp: stamp(approval), after: head)
			#expect(newest.hlc < next.hlc)
			#expect(try await reader.reviewHead(chat: .main) == (.record(next.ulid), approval))
			#expect(
				try await reader.reviewHead(chat: other) == (
					.record(elsewhereRecord.ulid), elsewhere
				))
		}

		@Test(arguments: [SharedChainStore.oneSwiftDataLog, .oneInMemoryLog])
		func theReviewChatsAreEachChatWithAReviewChainOnce(_ store: SharedChainStore) async throws {
			let writer = ledger(try store.logs(deviceId: phone).0)
			let approval = try reviewFixture("workout-review-approval")
			let claimed = try approval.claimed(Claim(id: claimID(1), action: .approve))
			let other = try #require(ChatID(rawValue: "other"))
			let marked = try #require(ChatID(rawValue: "marked"))
			let elsewhere = try WorkoutReviewPayload.decode(
				Data(
					String(decoding: try fixtureData("workout-review-approval"), as: UTF8.self)
						.replacingOccurrences(of: "\"chat\": \"main\"", with: "\"chat\": \"other\"")
						.utf8))
			#expect(try await writer.reviewChats() == [])
			let first = try await writer.commit(
				review: approval, stamp: stamp(approval), after: .empty)
			_ = try await writer.commit(
				review: claimed, stamp: stamp(claimed), after: .record(first.ulid))
			_ = try await writer.commit(review: elsewhere, stamp: stamp(elsewhere), after: .empty)
			try await writer.markPreparing(
				chat: marked, turn: TurnID(ulid: fixedUlid(7)),
				attempt: AttemptID(ulid: fixedUlid(8)),
				stamp: stamp(approval))

			#expect(try await writer.reviewChats() == [.main, other])
		}

		@Test func onlyTheOutcomeOfAReviewReachesAnotherDevice() async throws {
			let directory = try TestTemporaryFolders.make()
			let synced = try ModelContainerHandle.withoutCloudKit(
				storeURL: directory.appending(path: ModelContainerHandle.syncedStoreFileName))
			let device = { (name: String) in
				SwiftDataRecordLog(
					deviceId: DeviceID(rawValue: name), synced: synced,
					local: try ModelContainerHandle.deviceLocal(
						directory: directory.appending(path: name)))
			}
			let phone = ledger(try device("phone"))
			let later = FixedClock(now: "1998-06-13T09:00:00+02:00", timeZone: "Europe/Amsterdam")
			let pad = ledger(try device("pad"), clock: later)
			let review = try reviewFixture("workout-review-completed")
			let turn = TurnID(ulid: fixedUlid(7))
			let record = try await phone.commit(review: review, stamp: stamp(review), after: .empty)
			try await phone.markPreparing(
				chat: .main, turn: turn, attempt: AttemptID(ulid: fixedUlid(8)),
				stamp: stamp(review))
			let outcome = outcomeBody(review, ending: .completed)
			_ = try await phone.commit(synced: [.reviewOutcome(outcome)], stamp: stamp(review))
			_ = try await pad.commit(
				synced: [.reviewOutcome(outcomeBody(review, ending: .canceled))],
				stamp: stamp(review))

			#expect(try await pad.reviewOutcomes(chat: .main) == [review.id: outcome])
			#expect(try await pad.reviewHead(chat: .main) == (.empty, nil))
			#expect(try await pad.reviewPreparing(chat: .main, turn: turn) == [])
			#expect(try await phone.reviewOutcomes(chat: .main) == [review.id: outcome])
			#expect(try await phone.reviewHead(chat: .main) == (.record(record.ulid), review))
			#expect(
				try await phone.reviewPreparing(chat: .main, turn: turn).map(\.attempt) == [
					AttemptID(ulid: fixedUlid(8))
				])
		}

		@Test func anUnreadableNewestReviewStopsTheChainInsteadOfShowingTheOlderReview()
			async throws
		{
			let directory = try TestTemporaryFolders.make()
			let local = try ModelContainerHandle.deviceLocal(directory: directory)
			let log = SwiftDataRecordLog(
				deviceId: phone,
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: directory.appending(path: ModelContainerHandle.syncedStoreFileName)),
				local: local)
			let writer = ledger(log)
			let approval = try reviewFixture("workout-review-approval")
			let claimed = try approval.claimed(Claim(id: claimID(1), action: .approve))
			let older = try await writer.commit(
				review: approval, stamp: stamp(approval), after: .empty)
			let newest = try await writer.commit(
				review: claimed, stamp: stamp(claimed), after: .record(older.ulid))
			try makeNewerVersion(newest, in: local)
			let unreadable = RecordHead.unreadable(
				.newerVersion(kind: "workoutReview", version: 99, ulid: newest.ulid.rawValue))
			let reader = ledger(log)

			await #expect(throws: LedgerFailure.unavailable) {
				try await reader.reviewHead(chat: .main)
			}
			#expect(
				await commit(approval, on: reader, after: .record(older.ulid)).failure
					== .headMoved(unreadable))
		}

		@Test func aChatWhoseNewestReviewIsUnreadableStillOpensWithoutTheReview() async throws {
			let directory = try TestTemporaryFolders.make()
			let local = try ModelContainerHandle.deviceLocal(directory: directory)
			let log = SwiftDataRecordLog(
				deviceId: phone,
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: directory.appending(path: ModelContainerHandle.syncedStoreFileName)),
				local: local)
			let approval = try reviewFixture("workout-review-approval")
			let claimed = try approval.claimed(Claim(id: claimID(1), action: .approve))
			let writer = ledger(log)
			let older = try await writer.commit(
				review: approval, stamp: stamp(approval), after: .empty)
			let newest = try await writer.commit(
				review: claimed, stamp: stamp(claimed), after: .record(older.ulid))
			try makeNewerVersion(newest, in: local)
			let coach = await ReviewTurns().coach(over: log)

			_ = try await coach.mailbox(for: .main)

			#expect(try #require(await coach.currentSnapshot(.main)).review == nil)
		}

		@Test func anUnreadableNewestOutcomeStillTakesTheNextOutcome() async throws {
			let directory = try TestTemporaryFolders.make()
			let synced = try ModelContainerHandle.withoutCloudKit(
				storeURL: directory.appending(path: ModelContainerHandle.syncedStoreFileName))
			let log = SwiftDataRecordLog(
				deviceId: phone, synced: synced,
				local: try ModelContainerHandle.deviceLocal(directory: directory))
			let writer = ledger(log)
			let review = try reviewFixture("workout-review-completed")
			let query = RecordQuery(scope: .synced([.reviewOutcome]), chatId: .main)
			let first = try await writer.commit(
				synced: [.reviewOutcome(outcomeBody(review, ending: .completed))],
				stamp: stamp(review))
			try makeNewerVersion(try #require(first.first), in: synced)
			let reader = ledger(log)
			let head = try await reader.head(of: query)
			guard case .unreadable = head else {
				Issue.record("The newest outcome was read as \(head)")
				return
			}

			try await reader.commit(
				synced: .reviewOutcome(outcomeBody(review, ending: .canceled)),
				stamp: stamp(review),
				after: head, in: query)

			#expect(try await reader.reviewOutcomes(chat: .main).count == 1)
		}

		func makeNewerVersion(_ record: AthleteRecord, in handle: ModelContainerHandle) throws {
			let context = ModelContext(handle.container)
			let ulid = record.ulid.rawValue
			let row = try #require(
				try context.fetch(
					FetchDescriptor<StoredAthleteRecord>(predicate: #Predicate { $0.ulid == ulid })
				).first)
			row.bodyVersion = 99
			try context.save()
		}

		func outcomeBody(_ review: WorkoutReview, ending: ReviewOutcomeBody.Ending)
			-> ReviewOutcomeBody
		{
			ReviewOutcomeBody(
				chatId: review.chat, review: review.id, revision: review.revision,
				after: review.origin.turn, ending: ending,
				lines: [
					OutcomeLine(
						position: 0, action: .add, name: "Tempo ride", date: "1998-06-16",
						result: .saved)
				])
		}
	}
}

extension Result {
	var success: Success? {
		guard case .success(let success) = self else { return nil }
		return success
	}

	var failure: Failure? {
		guard case .failure(let failure) = self else { return nil }
		return failure
	}
}
