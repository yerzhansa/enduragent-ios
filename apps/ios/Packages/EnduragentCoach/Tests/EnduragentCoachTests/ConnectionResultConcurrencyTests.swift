import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension ConnectionResultTests {
	func entered(_ gate: FakeIntervalsReadGate) async throws {
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					Task { await gate.release() }
				}
			) { await gate.waitUntilEntered() } != nil)
	}

	func finished(_ task: Task<Void, Never>, releasing gate: FakeIntervalsReadGate) async throws {
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					task.cancel()
					Task { await gate.release() }
				}
			) { await task.value } != nil)
	}

	@Test func firstObservationPublishesWaitingThenReadsTheSavedConnection() async throws {
		try secrets.storeIntervalsConnection(testConnection)
		let gate = client.holdNextProfileRead()
		defer { Task { await gate.release() } }
		let coach = await coach()
		let statuses = await coach.observeStatus()
		try await entered(gate)
		let waiting = try #require(try await statuses.status { _ in true })
		#expect(try summary(waiting).profile == .waiting)
		#expect(client.wellnessReadCount == 0)
		await gate.release()
		let loaded = try await landed(in: statuses)
		#expect(loaded.athleteName == "Ada")
		#expect(loaded.wellness == .available(.noData(on: "1998-06-13")))
		#expect(client.profileReadCount == 1)
		#expect(try secrets.intervalsConnection() == testConnection)
	}

	@Test func blankReplacementKeepsTheSavedDisplayRefreshUsable() async throws {
		try secrets.storeIntervalsConnection(testConnection)
		let gate = client.holdNextProfileRead()
		defer { Task { await gate.release() } }
		let coach = await coach()
		let statuses = await coach.observeStatus()
		try await entered(gate)
		#expect(
			await coach.changeTraining(.replace(apiKey: " ", athlete: .keyOwner))
				== .refused(.blankReplacementKeepsCurrent))
		#expect(try summary(try await coach.observedStatus()).profile == .waiting)
		#expect(client.profileReadCount == 1)
		await gate.release()
		let current = try await landed(in: statuses)
		#expect(current.connectionID == testConnection.id)
		#expect(current.athleteName == "Ada")
		#expect(try secrets.intervalsConnection() == testConnection)
	}

	@Test func savedReceiptAndAthletePublishBeforeWellnessFinishes() async throws {
		let gate = client.holdNextWellnessRead()
		defer { Task { await gate.release() } }
		let coach = await coach()
		let statuses = await coach.observeStatus()
		let receipt = try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					Task { await gate.release() }
				}
			) { await coach.changeTraining(.replace(apiKey: "synthetic-key", athlete: .keyOwner)) })
		#expect(receipt.saveNotice?.key == Catalog.planViewEndedSaved)
		try await entered(gate)
		let reading = try #require(
			try await statuses.status {
				guard case .connected(let summary, _) = $0.training else { return false }
				return summary.athleteName == "Ada"
			})
		#expect(try summary(reading).wellness == .waiting)
		#expect(reading.notice?.key == Catalog.connectWellnessWaiting)
		await gate.release()
		_ = try await landed(in: statuses)
		#expect(client.profileReadCount == 1)
	}

	@Test func duplicateWellnessRetriesJoinAndStaleOrSuccessfulRetriesReadNothing() async throws {
		client.setWellnessOutcome(.failure(failure(503)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		_ = await coach.changeTraining(.replace(apiKey: "synthetic-key", athlete: .keyOwner))
		let failed = try await landed(in: statuses)
		client.setWellnessOutcome(.success([]))
		let gate = client.holdNextWellnessRead()
		defer { Task { await gate.release() } }
		let first = Task { await coach.retryTrainingDisplay(for: failed.connectionID) }
		try await entered(gate)
		let second = Task { await coach.retryTrainingDisplay(for: failed.connectionID) }
		await coach.retryTrainingDisplay(for: ConnectionID())
		await gate.release()
		try await finished(first, releasing: gate)
		try await finished(second, releasing: gate)
		await coach.retryTrainingDisplay(for: failed.connectionID)
		#expect(client.profileReadCount == 1)
		#expect(client.wellnessReadCount == 2)
		#expect(
			try summary(try await coach.observedStatus()).wellness
				== .available(.noData(on: "1998-06-13")))
	}

	@Test(arguments: [false, true])
	func lateProfileRetryCannotRestoreReplacedOrDisconnectedConnection(disconnect: Bool)
		async throws
	{
		client.setProfileOutcome(.failure(failure(503)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		_ = await coach.changeTraining(.replace(apiKey: "synthetic-a", athlete: .keyOwner))
		let failed = try await landed(in: statuses)
		client.setProfileOutcome(.success(AthleteProfile(id: "i1001", name: "Ada", ftp: 250)))
		let gate = client.holdNextProfileRead()
		defer { Task { await gate.release() } }
		let retry = Task { await coach.retryTrainingDisplay(for: failed.connectionID) }
		try await entered(gate)
		client.setProfileOutcome(.success(AthleteProfile(id: "i2002", name: "Bo", ftp: 240)))
		_ = await coach.changeTraining(
			disconnect ? .disconnect : .replace(apiKey: "synthetic-b", athlete: .keyOwner))
		let current = try secrets.intervalsConnection()
		if !disconnect { _ = try await landed(in: statuses) }
		await gate.release()
		try await finished(retry, releasing: gate)
		#expect(try secrets.intervalsConnection() == current)
		let status = try await coach.observedStatus()
		if disconnect {
			#expect(status.training == .unconnected)
		} else {
			#expect(try summary(status).connectionID == current?.id)
			#expect(try summary(status).athleteName == "Bo")
		}
	}

	@Test(arguments: [false, true])
	func lateWellnessRetryCannotRestoreReplacedOrDisconnectedConnection(disconnect: Bool)
		async throws
	{
		client.setWellnessOutcome(.failure(failure(503)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		_ = await coach.changeTraining(.replace(apiKey: "synthetic-a", athlete: .keyOwner))
		let failed = try await landed(in: statuses)
		client.setWellnessOutcome(
			.success([WellnessDay(date: "1998-06-13", fitness: 42, fatigue: nil, form: nil)]))
		let gate = client.holdNextWellnessRead()
		defer { Task { await gate.release() } }
		let retry = Task { await coach.retryTrainingDisplay(for: failed.connectionID) }
		try await entered(gate)
		client.setProfileOutcome(.success(AthleteProfile(id: "i2002", name: "Bo", ftp: 240)))
		client.setWellnessOutcome(
			.success([WellnessDay(date: "1998-06-13", fitness: 90, fatigue: nil, form: nil)]))
		_ = await coach.changeTraining(
			disconnect ? .disconnect : .replace(apiKey: "synthetic-b", athlete: .keyOwner))
		let current = try secrets.intervalsConnection()
		if !disconnect { _ = try await landed(in: statuses) }
		await gate.release()
		try await finished(retry, releasing: gate)
		#expect(try secrets.intervalsConnection() == current)
		let status = try await coach.observedStatus()
		if disconnect {
			#expect(status.training == .unconnected)
		} else {
			#expect(try summary(status).connectionID == current?.id)
			#expect(try summary(status).athleteName == "Bo")
			#expect(try summary(status).today?.fitness == 90)
		}
	}

	@Test func newerSameConnectionReadWinsAndAloneResolvesStoredAthlete() async throws {
		client.setProfileOutcome(.failure(failure(503)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		_ = await coach.changeTraining(.replace(apiKey: "synthetic-key", athlete: .keyOwner))
		let failed = try await landed(in: statuses)
		client.setProfileOutcome(.success(AthleteProfile(id: "i1001", name: "Old", ftp: 250)))
		let gate = client.holdNextProfileRead()
		defer { Task { await gate.release() } }
		let old = Task { await coach.retryTrainingDisplay(for: failed.connectionID) }
		try await entered(gate)
		client.setProfileOutcome(.success(AthleteProfile(id: "i2002", name: "Current", ftp: 240)))
		try #require(
			try await beforeDeadline(
				within: .hangGuard,
				onTimeout: {
					Task { await gate.release() }
				}
			) { await coach.lifecycle(.becameActive) } != nil)
		let current = try #require(try secrets.intervalsConnection())
		#expect(current.id == failed.connectionID)
		#expect(current.resolvedAthlete?.rawValue == "i2002")
		await gate.release()
		try await finished(old, releasing: gate)
		#expect(try summary(try await coach.observedStatus()).athleteName == "Current")
		#expect(try secrets.intervalsConnection() == current)
	}
}
