import EnduragentCoachFixtures
import Foundation
import Security
import Synchronization
import Testing

@testable import EnduragentCoach

extension CreditsClientTests {
	@Suite struct BillingIdentityTests {
		private let accountKey = "synthetic-openrouter-account"
		private let creditsKey = "synthetic-credits"
		private let accountModel = ModelID(rawValue: "test/account-model")
		private let phone = DeviceID(rawValue: "billing-proof-phone")

		@Test func creditsExhaustionPreservesSavedConversationAndMemory() async throws {
			let directory = try TestTemporaryFolders.make()
			let saved: ChatSnapshot
			let original: CreditsAccount
			do {
				let secrets = try identities(directory, method: .credits)
				original = try #require(try secrets.creditsAccount())
				let transport = FakeModelTransport()
				let coach = try await coach(directory, secrets: secrets, transport: transport)
				transport.respond = ScriptedReply.sequence([
					.toolCall(
						name: "memory_write",
						arguments:
							#"{"type":"memory","section":"schedule","content":"Rides with a group on Saturdays."}"#
					),
					.finish(reason: .toolCalls), .text("Saturday ride saved."),
					.finish(reason: .stop),
				])
				#expect(
					replyText(try await coach.sendAndSettle("Remember my Saturday ride"))
						== "Saturday ride saved.")
				let written = try #require(
					transport.requests.last?.messages.last { $0.role == .tool })
				#expect(
					try JSONValue.parse(written.content).objectFields["data"]?.objectFields[
						"saved"]?.boolValue == true)
				transport.respond = { _ in ScriptedReply([.fail(.http(status: 402))]) }
				let exhausted = try await coach.sendAndSettle("Plan my next ride")
				#expect(failure(exhausted) == .model(.accessExhausted(.credits)))
				#expect(turnNotice(of: exhausted)?.actions == [.buyCredits, .switchToOpenRouter])
				let balance = try await CreditsURLStub.withHandler({ request in
					if request.url?.path == "/catalog" { return Self.catalog }
					#expect(request.url?.host == "openrouter.test")
					#expect(request.url?.path == "/api/v1/key")
					#expect(
						request.value(forHTTPHeaderField: "Authorization")
							== "Bearer synthetic-credits")
					return .json(200, #"{"data":{"limit_remaining":0}}"#)
				}) { try await coach.credits.balance() }
				#expect(balance.credits.units == 0)
				#expect(balance.notice?.key == Catalog.creditsErrorExhausted)
				saved = try await snapshot(coach)
				#expect(
					saved.turns.map(\.athleteText) == [
						"Remember my Saturday ride", "Plan my next ride",
					])
				try assertRequests(transport, method: .credits)
				await coach.lifecycle(.willTerminate)
			}
			let secrets = try ICloudKeychainStore.fixture(directory: directory).store
			let transport = FakeModelTransport()
			let reopened = try await coach(directory, secrets: secrets, transport: transport)
			#expect(try await snapshot(reopened).turns == saved.turns)
			#expect(try await reopened.observedStatus().access.savedMethod == .credits)
			#expect(try secrets.accessSelection() == .init(.credits))
			#expect(try secrets.creditsAccount() == original)
			#expect(try secrets.openRouterAccountKey(at: .legacy) == accountKey)
			transport.respond = ScriptedReply.sequence([
				.toolCall(
					name: "memory_query",
					arguments: #"{"from":"1998-06-13","to":"1998-06-13","query":"schedule"}"#),
				.finish(reason: .toolCalls), .fail(.http(status: 402)),
			])
			#expect(
				failure(try await reopened.sendAndSettle("Recall my Saturday ride"))
					== .model(.accessExhausted(.credits)))
			let result = try #require(transport.requests.last?.messages.last { $0.role == .tool })
			#expect(result.content.contains("Rides with a group on Saturdays."))
			try assertRequests(transport, method: .credits)
			#expect(try await snapshot(reopened).turns.prefix(2).elementsEqual(saved.turns))
		}

		@Test func outOfCreditsNoticeKeepsBothActionsAfterReopeningAndInHistory() async throws {
			let directory = try TestTemporaryFolders.make()
			let offered: [RecoveryAction] = [.buyCredits, .switchToOpenRouter]
			do {
				let secrets = try identities(directory, method: .credits)
				let transport = FakeModelTransport(respond: { _ in
					ScriptedReply([.fail(.http(status: 402))])
				})
				let coach = try await coach(directory, secrets: secrets, transport: transport)
				let exhausted = try await coach.sendAndSettle("Plan my next ride")
				#expect(turnNotice(of: exhausted)?.actions == offered)
				await coach.lifecycle(.willTerminate)
			}
			let secrets = try ICloudKeychainStore.fixture(directory: directory).store
			let transport = FakeModelTransport()
			let reopened = try await coach(directory, secrets: secrets, transport: transport)
			#expect(
				try await snapshot(reopened).turns.map { turnNotice(of: $0.state)?.actions }
					== [offered])
			_ = await reopened.resetAndSettle(in: .main)
			let earlier = try #require(try await reopened.history().first?.id)
			let archived = try #require(try await reopened.archivedConversation(earlier))
			#expect(archived.turns.map { turnNotice(of: $0.state)?.actions } == [offered])
			#expect(try secrets.accessSelection() == .init(.credits))
		}

		@Test func exhaustedCreditsAreSavedAsTheFailureAlone() throws {
			let saved =
				#"{"failure":{"code":"accessExhausted","detail":"credits","domain":"model"},"kind":"failed","saved":{"calendarWrites":0,"ledgerEvents":0,"memorySections":0,"planSaves":0,"unverifiedCalendarWrites":0}}"#
			let settlement = Settlement.failed(.model(.accessExhausted(.credits)), saved: .none)
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys]
			#expect(
				String(decoding: try encoder.encode(SettlementPayload(settlement)), as: UTF8.self)
					== saved)
			#expect(
				try JSONDecoder().decode(SettlementPayload.self, from: Data(saved.utf8))
					.settlement() == settlement)
		}

		@Test(arguments: ["grant", "claim", "recover"], ["success", "unavailable", "persistence"])
		func creditsOperationsKeepOpenRouterAndReportFailures(operation: String, fault: String)
			async throws
		{
			let directory = try TestTemporaryFolders.make()
			let secrets = try identities(directory, method: .openRouterAccount)
			let backing = try ICloudKeychainStore.fixture(directory: directory).backing
			let guardedSecrets = ICloudKeychainStore(backing: backing)
			let original = try #require(try secrets.creditsAccount())
			let transport = FakeModelTransport()
			let coach = try await coach(directory, secrets: guardedSecrets, transport: transport)
			if fault == "persistence" {
				backing.failWrites(CredentialSlot.creditsAccount.rawValue, with: errSecNotAvailable)
			}
			let requests = Mutex<[URLRequest]>([])
			var reported: Int?
			try await CreditsURLStub.withHandler({ request in
				requests.withLock { $0.append(request) }
				if fault == "unavailable" { return .json(503, #"{"error":"unavailable"}"#) }
				switch operation {
				case "grant":
					return .json(
						200, #"{"kind":"grantMinted","key":"synthetic-new-credits","credits":200}"#)
				case "claim":
					return .json(
						200,
						#"{"kind":"claimMinted","key":"synthetic-new-credits","creditsAdded":500}"#)
				default:
					return .json(
						200,
						#"{"kind":"recovered","athleteId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","key":"synthetic-new-credits","credits":150}"#
					)
				}
			}) {
				do {
					reported = try await operate(
						operation, on: coach, token: original.appAccountToken)
				} catch let failure as CreditsFailure {
					#expect(fault == "unavailable")
					#expect(failure == .unavailable)
				} catch let failure as AccessUnavailable {
					#expect(fault == "persistence")
					#expect(failure == .secureStorageUnavailable)
				}
			}
			#expect(
				reported
					== (fault == "success"
						? (operation == "grant" ? 200 : operation == "claim" ? 500 : 150) : nil))
			let sent = requests.withLock { $0 }
			try #require(sent.count == 1)
			#expect(sent.first?.url?.host == "credits.test")
			#expect(sent.first?.url?.path == "/" + operation)
			#expect(sent.first?.value(forHTTPHeaderField: "Authorization") == nil)
			backing.failWrites(CredentialSlot.creditsAccount.rawValue, with: nil)
			let reopened = try ICloudKeychainStore.fixture(directory: directory).store
			#expect(try reopened.accessSelection() == accountSelection)
			#expect(try reopened.openRouterAccountKey(at: .legacy) == accountKey)
			if fault == "success" {
				#expect(try reopened.creditsAccount()?.key == "synthetic-new-credits")
				#expect(
					try reopened.creditsAccount()?.appAccountToken.uuidString.lowercased()
						== (operation == "recover"
							? "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
							: original.appAccountToken.uuidString.lowercased()))
			} else {
				#expect(try reopened.creditsAccount() == original)
			}
			transport.respond = ScriptedReply.sequence([
				.toolCall(
					name: "memory_query", arguments: #"{"from":"1998-06-13","to":"1998-06-13"}"#),
				.finish(reason: .toolCalls), .text("Your OpenRouter account still works."),
				.finish(reason: .stop),
			])
			#expect(
				replyText(try await coach.sendAndSettle("Read my notes after Credits setup"))
					== "Your OpenRouter account still works.")
			try #require(transport.requests.count == 2)
			#expect(transport.requests.last?.messages.contains { $0.role == .tool } == true)
			try assertRequests(transport, method: .openRouterAccount)
		}

		private var accountSelection: SavedAccessReference {
			.init(.openRouter(SavedOpenRouterReference(credential: .legacy, model: accountModel)))
		}

		private static var catalog: CreditsURLStub.Response {
			.json(200, #"{"purchasesEnabled":false,"creditsPerUsd":100,"packs":[]}"#)
		}

		private func identities(_ directory: URL, method: AccessMethod) throws
			-> ICloudKeychainStore
		{
			try FileManager.default.createDirectory(
				at: directory, withIntermediateDirectories: true)
			let secrets = try ICloudKeychainStore.fixture(directory: directory).store
			try secrets.storeCreditsAccount(
				CreditsAccount(appAccountToken: UUID(), key: creditsKey))
			try secrets.storeOpenRouterAccountKey(accountKey, at: .legacy)
			try secrets.storeAccessSelection(
				method == .credits ? .init(.credits) : accountSelection)
			return secrets
		}

		private func coach(
			_ directory: URL, secrets: ICloudKeychainStore, transport: FakeModelTransport
		) async throws -> Coach {
			let configuration = URLSessionConfiguration.ephemeral
			configuration.protocolClasses = [CreditsURLStub.self]
			configuration.timeoutIntervalForRequest = 20
			let session = URLSession(configuration: configuration)
			let worker = try #require(URL(string: "https://credits.test"))
			let router = try #require(URL(string: "https://openrouter.test/api/v1"))
			let coach = Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(
						log: try SwiftDataSuites.makeSwiftDataLog(
							deviceId: phone, directory: directory)),
					secrets: secrets, models: .scripted(transport),
					training: .fake { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
					credits: CreditsService {
						PhoneCreditsClient(
							vault: $0, workerBase: worker, openRouterBase: router, session: session)
					},
					host: ImmediateExecutionHost(),
					clock: FixedClock(
						now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam")),
				builtInModel: testModel, displayLocale: testDisplayLocale, coalescing: quickWindow)
			try await coach.recordConsent()
			return coach
		}

		private func snapshot(_ coach: Coach) async throws -> ChatSnapshot {
			try #require(
				try await firstSnapshot(in: await coach.observe(.main), within: .hangGuard) { _ in
					true
				})
		}

		private func assertRequests(_ transport: FakeModelTransport, method: AccessMethod) throws {
			try #require(!transport.requests.isEmpty)
			#expect(
				transport.requests.allSatisfy {
					$0.credential
						== ProviderCredential(
							secret: method == .credits ? creditsKey : accountKey, method: method)
						&& $0.model == (method == .credits ? testModel : accountModel)
				})
		}

		private func operate(_ operation: String, on coach: Coach, token: UUID) async throws -> Int
		{
			switch operation {
			case "grant":
				guard
					case .minted(let credits) = try await coach.credits.grant(
						deviceCheck: Data([1]))
				else { throw CreditsFailure.unexpectedResponse(status: 200) }
				return credits.units
			case "claim":
				guard
					case .minted(let credits) = try await coach.credits.claim(
						signedTransaction: "synthetic.receipt.signature", appAccountToken: token)
				else { throw CreditsFailure.unexpectedResponse(status: 200) }
				return credits.units
			default:
				return try await coach.credits.recover(
					signedTransaction: "synthetic.receipt.signature"
				).credits.units
			}
		}
	}
}
