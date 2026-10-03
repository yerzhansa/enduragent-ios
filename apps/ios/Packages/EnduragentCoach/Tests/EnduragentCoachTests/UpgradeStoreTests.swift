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
			#expect(status.providerConsent == ProviderConsent(at: clock.now))
			#expect(!status.needsProviderConsent)
			#expect(transport.requests.isEmpty)
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

		private func open(_ scenario: String, folder: String = "Fixtures/v1-upgrade") throws
			-> SwiftDataRecordLog
		{
			let source = try #require(
				Bundle.module.url(
					forResource: scenario, withExtension: nil, subdirectory: folder))
			let root = try TestTemporaryFolders.make()
			try FileManager.default.copyItem(at: source, to: root)
			return SwiftDataRecordLog(
				deviceId: DeviceID(
					rawValue: folder == "Fixtures" ? scenario : "v1-upgrade-fixture"),
				synced: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "synced-records.store")),
				local: try ModelContainerHandle.withoutCloudKit(
					storeURL: root.appending(path: "local-records.store")))
		}
	}
}
