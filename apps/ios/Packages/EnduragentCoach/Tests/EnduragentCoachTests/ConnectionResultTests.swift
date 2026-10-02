import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ConnectionResultTests {
	let client = FakeIntervalsClient(athleteName: "Ada", ftp: 250)
	let backing = FixtureSecretStoreBacking()
	let secrets: ICloudKeychainStore

	init() throws {
		secrets = ICloudKeychainStore(backing: backing)
		try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
	}

	func coach() async -> Coach {
		await makeCoach(
			transport: FakeModelTransport(), intervals: client, store: InMemoryRecordLog(),
			secrets: secrets)
	}

	func failure(_ status: Int) -> IntervalsError {
		IntervalsError(code: "http", details: "synthetic private detail", status: status)
	}

	func summary(_ status: CoachStatus) throws -> IntervalsSummary {
		guard case .connected(let summary, _) = status.training else {
			throw TestWaitDeadlineExceeded()
		}
		return summary
	}

	func landed(in statuses: AsyncStream<CoachStatus>) async throws -> IntervalsSummary {
		try summary(
			try #require(
				try await statuses.status {
					guard case .connected(let summary, _) = $0.training else { return false }
					if case .failed = summary.profile { return true }
					guard case .available = summary.profile else { return false }
					return summary.wellness != .waiting
				}))
	}

	@Test func blankAndFailedWriteHaveSeparateSaveGuidanceAndKeepConnection() async throws {
		try secrets.storeIntervalsConnection(testConnection)
		let coach = await coach()
		let statuses = await coach.observeStatus()
		let blank = await coach.changeTraining(.replace(apiKey: " \n ", athlete: .keyOwner))
		#expect(blank == .refused(.blankReplacementKeepsCurrent))
		#expect(blank.saveNotice?.key.rawValue == "connect.error.blank")
		backing.failNextWrite = true
		let failed = await coach.changeTraining(
			.replace(apiKey: "synthetic-new", athlete: .keyOwner))
		#expect(failed.saveNotice?.key.rawValue == "connect.error.notSaved")
		guard case .failedPreviousKept = failed else {
			Issue.record("Expected the previous connection to survive")
			return
		}
		let previous = try #require(
			try await statuses.status {
				guard case .connected(let summary, _) = $0.training else { return false }
				return summary.connectionID == testConnection.id
			})
		#expect(try summary(previous).connectionID == testConnection.id)
		#expect(try secrets.intervalsConnection() == testConnection)
	}

	@Test(arguments: [
		(401, TrainingFailure.credentialRejected), (403, .credentialRejected),
		(422, .requestRejected), (408, .temporarilyUnavailable), (429, .temporarilyUnavailable),
		(503, .temporarilyUnavailable),
	])
	func profileFailureReportsSavedAndOffersTheRightAction(status: Int, expected: TrainingFailure)
		async throws
	{
		client.setProfileOutcome(.failure(failure(status)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		let outcome = await coach.changeTraining(
			.replace(apiKey: "synthetic-key", athlete: .keyOwner))
		guard case .replaced(let receipt, _) = outcome else {
			Issue.record("Expected the nonempty key to be saved")
			return
		}
		#expect(outcome.saveNotice?.key == Catalog.planViewEndedSaved)
		let active = try #require(try secrets.intervalsConnection())
		let display = try await landed(in: statuses)
		#expect(receipt.connectionID == active.id)
		#expect(display.profile == .failed(expected))
		#expect(display.athleteName == nil)
		#expect(display.today == nil)
		#expect(
			display.action
				== (expected == .temporarilyUnavailable ? .retry(active.id) : .reviewConnection))
		#expect(
			display.notice?.key
				== (expected == .temporarilyUnavailable
					? CatalogKey(rawValue: "connect.error.profileUnavailable")
					: expected == .credentialRejected
						? Catalog.connectErrorRejected : Catalog.coachErrorIntervalsCredentials))
		#expect(client.wellnessReadCount == 0)
		#expect(client.profileReadCount == 1)
	}

	@Test func networkProfileFailureRecoversUsingSavedKeyAndID() async throws {
		client.setProfileOutcome(.failure(URLError(.notConnectedToInternet)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		_ = await coach.changeTraining(.replace(apiKey: "synthetic-key", athlete: .keyOwner))
		let failed = try await landed(in: statuses)
		#expect(failed.profile == .failed(.temporarilyUnavailable))
		let active = try #require(try secrets.intervalsConnection())
		client.setProfileOutcome(.success(AthleteProfile(id: "i1001", name: "Ada", ftp: 250)))
		client.setWellnessOutcome(
			.success([WellnessDay(date: "1998-06-13", fitness: 42, fatigue: nil, form: nil)]))
		await coach.retryTrainingDisplay(for: active.id)
		let recovered = try summary(try await coach.observedStatus())
		#expect(recovered.athleteName == "Ada")
		#expect(recovered.today?.fitness == 42)
		#expect(recovered.today?.fatigue == nil)
		#expect(recovered.today?.form == nil)
		let resolved = try #require(try secrets.intervalsConnection())
		#expect(resolved.id == active.id)
		#expect(resolved.credential == active.credential)
		#expect(resolved.resolvedAthlete?.rawValue == "i1001")
		#expect(client.profileReadCount == 2)
		#expect(client.wellnessReadCount == 1)
	}

	@Test func wellnessRejectionKeepsAthleteWithoutRejectingSavedKey() async throws {
		client.setWellnessOutcome(.failure(failure(403)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		let outcome = await coach.changeTraining(
			.replace(apiKey: "synthetic-key", athlete: .keyOwner))
		guard case .replaced = outcome else {
			Issue.record("Expected a saved connection")
			return
		}
		let display = try await landed(in: statuses)
		#expect(display.athleteName == "Ada")
		#expect(display.today == nil)
		#expect(display.notice?.key.rawValue == "connect.error.wellnessRejected")
		#expect(display.action == .reviewConnection)
		#expect(client.profileReadCount == 1)
	}

	@Test(arguments: [401, 403, 422, 408, 429, 503])
	func wellnessRetryReadsOnlyWellnessAndRetainsAthlete(status: Int) async throws {
		client.setWellnessOutcome(.failure(failure(503)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		_ = await coach.changeTraining(.replace(apiKey: "synthetic-key", athlete: .keyOwner))
		let failed = try await landed(in: statuses)
		#expect(failed.notice?.key.rawValue == "connect.error.wellnessUnavailable")
		let active = try #require(try secrets.intervalsConnection())
		let profileReads = client.profileReadCount
		client.setWellnessOutcome(.failure(failure(status)))
		await coach.retryTrainingDisplay(for: active.id)
		let retried = try summary(try await coach.observedStatus())
		#expect(retried.athleteName == "Ada")
		guard case .available(let profile) = retried.profile else {
			Issue.record("Expected the resolved athlete to remain")
			return
		}
		#expect(profile.athleteID.rawValue == "i1001")
		#expect(
			profile.wellness
				== .failed(
					[408, 429, 503].contains(status) ? .temporarilyUnavailable : .requestRejected))
		#expect(client.profileReadCount == profileReads)
		#expect(client.wellnessReadCount == 2)
		#expect(try secrets.intervalsConnection() == active)
	}

	@Test(arguments: [
		[WellnessDay](), [WellnessDay(date: "1998-06-13", fitness: 42, fatigue: nil, form: nil)],
		[WellnessDay(date: "1998-06-13", fitness: nil, fatigue: nil, form: nil)],
	])
	func wellnessRepresentsEmptyAndMissingValuesWithoutNumbers(days: [WellnessDay]) async throws {
		client.setWellnessOutcome(.failure(failure(503)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		_ = await coach.changeTraining(.replace(apiKey: "synthetic-key", athlete: .keyOwner))
		let failed = try await landed(in: statuses)
		client.setWellnessOutcome(.success(days))
		await coach.retryTrainingDisplay(for: failed.connectionID)
		let display = try summary(try await coach.observedStatus())
		#expect(
			display.wellness
				== .available(
					days.first.map(IntervalsWellnessResult.day) ?? .noData(on: "1998-06-13")))
		#expect(display.today == days.first)
		#expect(display.today?.fatigue == nil)
		#expect(display.today?.form == nil)
		#expect(client.profileReadCount == 1)
		#expect(display.notice?.key.rawValue == (days.isEmpty ? "connect.wellness.empty" : nil))
	}

	@Test func invalidOwnerIDNeverBecomesAnAvailableProfile() async throws {
		client.setProfileOutcome(.success(AthleteProfile(id: "0", name: "Unknown", ftp: nil)))
		let coach = await coach()
		let statuses = await coach.observeStatus()
		_ = await coach.changeTraining(.replace(apiKey: "synthetic-key", athlete: .keyOwner))
		let display = try await landed(in: statuses)
		#expect(display.profile == .failed(.temporarilyUnavailable))
		#expect(client.wellnessReadCount == 0)
	}
}
