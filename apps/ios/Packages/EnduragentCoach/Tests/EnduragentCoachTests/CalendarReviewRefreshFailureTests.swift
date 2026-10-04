import EnduragentCoachFixtures
import Testing

@testable import EnduragentCoach

extension DurableCalendarWriteTests {
	@Test func failedImportReviewReadDisablesThePresentedReviewAndRestoresOnTheNextImport()
		async throws
	{
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let store = ImportingRecordLog(inner: faults)
		let fixture = await fixture(url: url, store: store)
		let (_, token) = try await proposal(on: fixture.coach, model: fixture.model)
		await fixture.coach.stop(.main)
		_ = await fixture.coach.decide(.presented(token.ref), in: .main)
		let ready = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		let observed = ImportSnapshots(await fixture.coach.observe(.main))
		try await waitUntil { observed.latest?.review == ready }
		faults.failNextFetch(in: ProposalPolicy.proposalQuery(.main).scope)
		store.notifyImport()
		try await waitUntil {
			fixture.coach.diagnostics.entries.contains {
				$0.event == .importsUnavailable(.main, .unavailable)
			}
		}
		let failed = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(failed.ref == ready.ref)
		#expect(failed.state == .storageUnavailable(try #require(ready.content), .approveOrCancel))
		#expect(failed.controls == .none)
		#expect(failed.notice?.key == Catalog.reviewStorageUnavailable)
		#expect(
			fixture.coach.diagnostics.entries.contains {
				$0.event == .reviewUnavailable(.main, .unavailable)
			})
		try await waitUntil { observed.latest?.review == failed }
		#expect(observed.latest?.review?.state == failed.state)
		store.notifyImport()
		try await waitUntil { observed.latest?.review == ready }
		#expect(await fixture.coach.currentSnapshot(.main)?.review == ready)
		#expect(server.posts.isEmpty)
		await fixture.coach.lifecycle(.willTerminate)
	}

	@Test(arguments: [false, true])
	func failedRefreshRestoresRecoveryWithoutRepeatingTheWrite(repeatAvailable: Bool) async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(502) }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let fixture = await fixture(url: url, store: faults)
		let (turn, token) = try await proposal(on: fixture.coach, model: fixture.model)
		_ = await fixture.coach.decide(.approve(token), in: .main)
		await fixture.coach.stop(.main)
		if repeatAvailable {
			server.state.withLock { $0.readResponse = .body("[]") }
			_ = await fixture.coach.decide(.checkAgain(token.ref), in: .main)
		}
		let ready = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		faults.failFetches = true
		_ = await fixture.coach.decide(.presented(ready.ref), in: .main)
		let failed = try #require(await fixture.coach.currentSnapshot(.main)?.review)
		#expect(failed.ref == ready.ref)
		#expect(failed.cards == ready.cards)
		#expect(failed.controls == .none)
		#expect(
			failed.state
				== .storageUnavailable(
					try #require(ready.content),
					repeatAvailable ? .retryRemainingOrCancel : .checkAgain))
		#expect(failed.notice?.key == Catalog.reviewStorageUnavailable)
		#expect(
			failed.notice.map { LanguageTag.en.phrasebook.say($0.key, $0.vars) }
				== "Couldn't read the saved workout review. Its buttons are temporarily disabled.")
		#expect(
			await fixture.coach.decide(.checkAgain(failed.ref), in: .main) == .storageUnavailable)
		#expect(await fixture.coach.currentSnapshot(.main)?.review == failed)
		#expect(server.posts.count == 1)
		faults.failFetches = false
		#expect(
			await fixture.coach.decide(.checkAgain(failed.ref), in: .main) == .presentationRecorded)
		#expect(await fixture.coach.currentSnapshot(.main)?.review == ready)
		#expect(server.posts.count == 1)
		#expect(
			(turnNotice(of: try #require(await fixture.coach.state(of: turn)))?.actions ?? [])
				.isEmpty
		)
		server.state.withLock { $0.readResponse = .success }
		#expect(
			await fixture.coach.decide(.checkAgain(ready.ref), in: .main)
				== .applied([ReviewReceipt(index: 0, result: .confirmed(eventId: "1"))]))
		#expect(await fixture.coach.currentSnapshot(.main)?.review == nil)
		#expect(server.posts.count == 1)
		#expect(server.events.count == 1)
	}
	@Test func failedReadPreservesCancelOnlyButtonsOnAnAthleteMismatch() async throws {
		let server = try CalendarWriteServer()
		let url = try await server.start()
		defer { server.stop() }
		server.state.withLock { $0.response = .status(502) }
		let faults = FaultInjectingRecordLog(wrapping: InMemoryRecordLog())
		let fixture = await fixture(url: url, store: faults)
		let secrets = keyedSecrets()
		let coach = await makeCoach(
			transport: fixture.model, intervals: fixture.client, store: faults, secrets: secrets)
		let (_, token) = try await proposal(on: coach, model: fixture.model)
		_ = await coach.decide(.approve(token), in: .main)
		await coach.stop(.main)
		try secrets.storeIntervalsConnection(
			IntervalsConnection(
				id: ConnectionID(), credential: .apiKey("test-athlete-b"), selection: .keyOwner,
				resolvedAthlete: IntervalsAthleteID(rawValue: "i2002")))
		server.state.withLock { $0.athleteID = "i2002" }
		_ = await coach.decide(.presented(token.ref), in: .main)
		let ready = try #require(await coach.currentSnapshot(.main)?.review)
		guard case .cancelOnly = ready.controls else {
			Issue.record("Expected Cancel only for a different athlete")
			return
		}
		faults.failFetches = true
		_ = await coach.decide(.presented(ready.ref), in: .main)
		let failed = try #require(await coach.currentSnapshot(.main)?.review)
		#expect(failed.state == .storageUnavailable(try #require(ready.content), .cancelOnly))
		#expect(failed.controls == .none)
		let calls = server.state.withLock { $0.requests.count }
		faults.failFetches = false
		#expect(await coach.decide(.checkAgain(failed.ref), in: .main) == .presentationRecorded)
		#expect(await coach.currentSnapshot(.main)?.review == ready)
		#expect(server.state.withLock { $0.requests.count } == calls)
	}

}
