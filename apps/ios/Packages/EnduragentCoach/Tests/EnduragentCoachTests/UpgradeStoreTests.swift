import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

extension SwiftDataSuites {
	@Suite struct UpgradeStoreTests {
		@Test func preVaultClaimsStayUnconnectedAndTheNextTurnUsesTheLegacyKey() async throws {
			let log = try open("pre-vault-5de5c782", folder: "Fixtures")
			let claims = try await log.fetch(RecordQuery(scope: .deviceLocal([.turnClaim])))
			#expect(claims.skipped.isEmpty)
			#expect(claims.records.count == 1)
			#expect(claims.records.allSatisfy { $0.account == .unconnected })
			let directory = try TestTemporaryFolders.make()
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			try Data(#"{"intervalsApiKey":"fixture-pre-vault-key"}"#.utf8).write(
				to: directory.appending(path: "secrets.json"))
			let secrets = try ICloudKeychainStore.fixture(directory: directory).store
			try secrets.storeCreditsAccount(CreditsAccount(appAccountToken: UUID(), key: testKey))
			let transport = FakeModelTransport(
				respond: ScriptedReply.sequence([.text("Connected reply"), .finish(reason: .stop)]))
			let coach = await makeCoach(transport: transport, store: log, secrets: secrets)
			#expect(
				try secrets.intervalsConnection()?.credential == .apiKey("fixture-pre-vault-key"))
			#expect(try await coach.history().isEmpty)
			#expect(
				await coach.currentSnapshot(.main)?.turns.first?.athleteText
					== "What did my training look like this week?")
			_ = try await coach.sendAndSettle("Remember that I ride with a group on Saturdays")
			let account = try #require(try secrets.intervalsConnection()?.account)
			#expect(account != .unconnected)
			let upgraded = try await log.fetch(RecordQuery(scope: .deviceLocal([.turnClaim])))
			#expect(upgraded.skipped.isEmpty)
			#expect(upgraded.records.map(\.account) == [.unconnected, account])
		}

		@Test func build2bbe2eeKeepsMemoryReviewHistoryAndConsent() async throws {
			let log = try open("build-2bbe2ee", folder: "Fixtures")
			let clock = FixedClock(now: "1998-06-15T08:00:00Z", timeZone: "Europe/Ljubljana")
			let transport = FakeModelTransport()
			let coach = await makeCoach(
				transport: transport, store: log, clock: clock, consent: false)
			#expect(
				try await coach.memory.fullContext(for: testConnection.account).contains(
					"Rides with a group on Saturdays."))
			let review = try #require(await coach.currentSnapshot(.main)?.review)
			#expect(review.authority == .thisDevice)
			#expect(review.cards.count == 1)
			#expect(review.cards.first?.date == "1998-06-16")
			#expect(review.totals.additions == 1)
			let history = try await coach.history()
			#expect(history.count == 1)
			let summary = try #require(history.first)
			#expect(summary.reason == .newConversation)
			let archive = try #require(try await coach.archivedConversation(summary.id))
			#expect(
				archive.turns.map(\.athleteText) == [
					"Remember that I ride with a group on Saturdays"
				])
			#expect(
				archive.turns.compactMap { replyText($0.state) } == [
					"Noted. I'll remember you ride with a group on Saturdays."
				])
			let status = try await coach.observedStatus()
			let agreements = try await log.fetch(
				RecordQuery(scope: .deviceLocal([.providerConsent])))
			#expect(
				agreements.records.last?.body
					== .deviceLocal(.providerConsent(ProviderConsent(legacyAt: clock.now))))
			#expect(status.acceptedConsent == nil)
			#expect(status.needsProviderConsent)
			#expect(transport.requests.isEmpty)
		}

		@Test func build2bbe2eeClaimsKeepTheContinuedProcessingLeaseTheyRecorded() async throws {
			let log = try open("build-2bbe2ee", folder: "Fixtures")
			let claims = try await log.fetch(RecordQuery(scope: .deviceLocal([.turnClaim])))
			#expect(claims.skipped.isEmpty)
			let leases = claims.records.compactMap { record -> LeaseKind? in
				guard case .deviceLocal(.turnClaim(let body)) = record.body else { return nil }
				return body.lease
			}
			#expect(leases == [.continuedProcessing, .continuedProcessing])
		}

		@Test func testUpgradeHistory() async throws {
			let log = try open("history")
			let coach = await makeCoach(transport: FakeModelTransport(), store: log)
			let snapshot = try #require(await coach.currentSnapshot(.main))
			#expect(snapshot.opening == .welcome)
			#expect(snapshot.turns.isEmpty)
			let history = try await coach.history()
			#expect(history.count == 2)
			#expect(history.map(\.reason) == [.earlierChat, .earlierChat])
			#expect(
				history.map(\.firstQuestion) == [
					"Remember that I ride with a group on Saturdays",
					"What did my training look like this week?",
				])
			for summary in history {
				let archive = try #require(try await coach.archivedConversation(summary.id))
				#expect(archive.turns.count == 1)
				#expect(archive.turns.compactMap { replyText($0.state) }.count == 1)
			}
		}

		@Test func pendingV1ReviewIsReadOnly() async throws {
			let log = try open("review")
			let transport = FakeModelTransport()
			let coach = await makeCoach(transport: transport, store: log)
			let review = try #require(await coach.currentSnapshot(.main)?.review)
			#expect(review.authority == .readOnly)
			#expect(review.controls == .none)
			#expect(review.notice?.key == Catalog.reviewEarlierVersion)
			#expect(transport.requests.isEmpty)
			let page = try await log.fetch(
				RecordQuery(
					scope: .deviceLocal([.pendingProposal, .proposalCleared])))
			#expect(page.skipped.isEmpty)
			#expect(kinds(page.records) == ["pendingProposal"])
		}

		@Test func build6833d90fOpenReviewClosesOnceAtUpgrade() async throws {
			let seed = try await M2Seed(
				try open("open-review", folder: M2Seed.folder, device: M2Seed.device))

			await (try seed.desk()).recover()
			await (try seed.desk()).recover()

			#expect(
				try await seed.outcomes() == [
					ReviewOutcomeBody(
						chatId: .main, review: seed.review, revision: ReviewRevision(rawValue: 1),
						after: seed.turn, ending: .closedAtUpgrade, lines: [])
				])
			#expect(try await seed.chain().isEmpty)
			#expect(seed.calendar.calls.isEmpty)
		}

		@Test func build6833d90fUnknownWriteBecomesOneUnconfirmedChange() async throws {
			let seed = try await M2Seed(
				try open("unknown-write", folder: M2Seed.folder, device: M2Seed.device))
			seed.calendar.failReads()

			await (try seed.desk()).recover()
			await (try seed.desk()).recover()

			let chain = try await seed.chain()
			#expect(chain.count == 1)
			let review = try #require(chain.first)
			#expect(review.id == seed.review)
			#expect(review.account == seed.account)
			#expect(review.origin.turn == seed.turn)
			guard case .waiting(.unconfirmed) = review.stage else {
				Issue.record("the unknown write did not become an unconfirmed change")
				return
			}
			let added = try seed.added(review)
			#expect(added.identity == seed.identity)
			#expect(added.identity.externalID == "cycling-coach:\(seed.identity.uid)")
			#expect(added.payload.date == "1998-06-16")
			#expect(added.payload.name == "Endurance with tempo")
			#expect(try await seed.outcomes().isEmpty)
			#expect(seed.calendar.writes.isEmpty)
		}

		@Test(arguments: M2Seed.Landing.allCases)
		func build6833d90fUnknownAddFoundOnTheCalendarFinishesAsSeen(_ landing: M2Seed.Landing)
			async throws
		{
			let seed = try await M2Seed(
				try open("unknown-write", folder: M2Seed.folder, device: M2Seed.device))
			seed.calendar.failReads()
			await (try seed.desk()).recover()
			let added = try seed.added(try #require(try await seed.chain().first))
			switch landing {
			case .bulkUpsert:
				_ = await seed.calendar.base.write(.create(added.payload, identity: seed.identity))
			case .singleCreate:
				seed.calendar.base.events.append(
					CalendarEvent(
						description:
							"- 10m 55-65%\n\n2x\n- 10m 190-225w\n- 5m Z1-Z2\n\n- 10m 55-65%",
						type: "Ride", id: EventID(rawValue: 7001),
						startDateLocal: "1998-06-16T00:00:00", name: "Endurance with tempo",
						category: "WORKOUT", externalId: seed.identity.externalID,
						uid: seed.identity.uid, tags: [IntervalsPolicy.coachTag], coachCreated: true
					))
			}
			seed.calendar.restoreReads()

			await (try seed.desk()).recover()

			#expect(try await seed.chain().last?.stage == .completed)
			#expect(
				try await seed.outcomes().map(\.lines) == [
					[
						OutcomeLine(
							position: 0, action: .add, name: "Endurance with tempo",
							date: "1998-06-16",
							result: .seenOnCalendar)
					]
				])
			#expect(seed.calendar.writes.isEmpty)
		}

		@Test func build6833d90fUnknownAddNotFoundIsApprovedAgainUnderTheSameExternalID()
			async throws
		{
			let seed = try await M2Seed(
				try open("unknown-write", folder: M2Seed.folder, device: M2Seed.device))
			let desk = try seed.desk()

			await desk.recover()

			let review = try #require(try await seed.chain().last)
			#expect(review.stage == .waiting(.approval(.interruptedBeforeWriting)))
			let added = try seed.added(review)
			let shown = try #require(try await desk.snapshot(chat: .main))
			#expect(await desk.decide(.presented(shown.ref)) == .presentationRecorded)
			guard
				case .armed(_, let token) = try #require(try await desk.snapshot(chat: .main))
					.controls
			else {
				Issue.record("the interrupted upgraded add offered no Approve")
				return
			}

			guard case .completed = await desk.decide(.approve(token)) else {
				Issue.record("approving the upgraded add did not complete")
				return
			}

			#expect(seed.calendar.writes == [.create(added.payload, identity: seed.identity)])
			#expect(
				seed.calendar.base.events.compactMap(\.externalId) == [seed.identity.externalID])
		}

		@Test func build6833d90fUnknownWriteFromAnotherDeviceGetsNoReview() async throws {
			let seed = try await M2Seed(
				try open("unknown-write", folder: M2Seed.folder, device: "another-phone"))

			await (try seed.desk()).recover()
			await (try seed.desk()).recover()

			#expect(try await seed.chain().isEmpty)
			#expect(try await seed.outcomes().isEmpty)
			#expect(seed.calendar.calls.isEmpty)
		}

		@Test func build6833d90fCompletedReviewsPlanNothingAndKeepTheirRecords() async throws {
			let log = try open("completed", folder: M2Seed.folder, device: M2Seed.device)
			let synced = try await log.fetch(RecordQuery(scope: .everySynced))
			let local = try await log.fetch(RecordQuery(scope: .everyDeviceLocal))
			let seed = try await M2Seed(log)

			await (try seed.desk()).recover()
			await (try seed.desk()).recover()

			#expect(synced.skipped.isEmpty)
			#expect(local.skipped.isEmpty)
			#expect(try await log.fetch(RecordQuery(scope: .everySynced)) == synced)
			#expect(try await log.fetch(RecordQuery(scope: .everyDeviceLocal)) == local)
			#expect(seed.calendar.calls.isEmpty)
		}

		@Test func build6833d90fOpenReviewClosesOnceWhenTwoDesksRecoverTogether() async throws {
			let log = try open("open-review", folder: M2Seed.folder, device: M2Seed.device)
			let seed = try await M2Seed(log)
			let held = HeldScopeReadLog(
				inner: log, holding: .synced([.reviewOutcome]), .afterReading)
			let late = try seed.desk(over: held)
			let lateRecover = Task { await late.recover() }
			try await held.waitUntilReached()

			await (try seed.desk()).recover()
			held.release()
			await lateRecover.value

			#expect(try await seed.outcomes().map(\.review) == [seed.review])
			#expect(try await seed.chain().isEmpty)
		}

		@Test func build6833d90fUnknownWriteSettledByOneDeskIsNotUpgradedAgainByAnother()
			async throws
		{
			let log = try open("unknown-write", folder: M2Seed.folder, device: M2Seed.device)
			let seed = try await M2Seed(log)
			let held = HeldScopeReadLog(
				inner: log, holding: .deviceLocal([.workoutReview]), .beforeReading)
			let late = try seed.desk(over: held)
			let lateRecover = Task { await late.recover() }
			try await held.waitUntilReached()
			let first = try seed.desk()
			seed.calendar.failReads()
			await first.recover()
			let added = try seed.added(try #require(try await seed.chain().first))
			_ = await seed.calendar.base.write(.create(added.payload, identity: seed.identity))
			seed.calendar.restoreReads()
			await first.recover()
			#expect(try await seed.chain().last?.stage == .completed)

			held.release()
			await lateRecover.value

			let chain = try await seed.chain()
			#expect(chain.filter { if case .waiting = $0.stage { true } else { false } }.count == 1)
			#expect(chain.last?.stage == .completed)
			#expect(try await seed.outcomes().map(\.ending) == [.completed])
			#expect(seed.calendar.writes.isEmpty)
		}

		@Test func build6833d90fUnknownWriteCanceledOnOneDeskIsNotRevivedByAnother() async throws {
			let log = try open("unknown-write", folder: M2Seed.folder, device: M2Seed.device)
			let seed = try await M2Seed(log)
			let held = HeldScopeReadLog(
				inner: log, holding: .deviceLocal([.workoutReview]), .beforeReading)
			let late = try seed.desk(over: held)
			let lateRecover = Task { await late.recover() }
			try await held.waitUntilReached()
			let first = try seed.desk()
			seed.calendar.failReads()
			await first.recover()
			let shown = try #require(try await first.snapshot(chat: .main))
			#expect(await first.decide(.presented(shown.ref)) == .presentationRecorded)
			guard
				case .armed(.checkAgainOrCancel, let token) = try #require(
					try await first.snapshot(chat: .main)
				).controls
			else {
				Issue.record("the upgraded unconfirmed change offered no Cancel")
				return
			}
			guard case .canceled = await first.decide(.cancel(token)) else {
				Issue.record("canceling the upgraded unconfirmed change did not cancel it")
				return
			}
			seed.calendar.restoreReads()

			held.release()
			await lateRecover.value

			let chain = try await seed.chain()
			#expect(!chain.contains { $0.stage == .waiting(.approval(.interruptedBeforeWriting)) })
			guard case .canceled = chain.last?.stage else {
				Issue.record("another desk revived the canceled upgraded change")
				return
			}
			#expect(try await seed.outcomes().map(\.ending) == [.canceled])
			#expect(seed.calendar.writes.isEmpty)
		}

		private func open(
			_ scenario: String, folder: String = "Fixtures/v1-upgrade", device: String? = nil
		) throws -> SwiftDataRecordLog {
			let source = try #require(
				Bundle.module.url(
					forResource: scenario, withExtension: nil, subdirectory: folder))
			let root = try TestTemporaryFolders.make()
			try FileManager.default.copyItem(at: source, to: root)
			return SwiftDataRecordLog(
				deviceId: DeviceID(
					rawValue: device ?? (folder == "Fixtures" ? scenario : "v1-upgrade-fixture")),
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "synced-records.store")),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local-records.store")))
		}
	}
}
