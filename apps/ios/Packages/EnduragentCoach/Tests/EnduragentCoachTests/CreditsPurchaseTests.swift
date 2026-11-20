import EnduragentCoachFixtures
import Foundation
import Security
import Testing

@testable import EnduragentCoach

@Suite struct CreditsPurchaseTests {
	private static let small = CreditPack(
		id: "icu.enduragent.app.credits.small", credits: Credits(units: 401))
	private static let large = CreditPack(
		id: "icu.enduragent.app.credits.large", credits: Credits(units: 1606))
	private static let offer = CreditsOffer(pack: small, displayPrice: "$4.99")
	private static let recordKey = "synthetic-record-key"

	@Test func aPurchaseAddsCreditsAndFinishes() async throws {
		let (coach, credits, store, _) = try await purchaseSetup()
		credits.claimResult = .success(.toppedUp(creditsAdded: Credits(units: 401)))
		let notice = await coach.buyCredits(Self.offer, in: store)
		#expect(sentence(notice) == "Added 401 credits")
		#expect(store.bought == [Self.small.id])
		#expect(store.finished == [1])
		#expect(credits.calls == [.claim(transactionLength: "fake.signed.\(Self.small.id)".count)])
	}

	@Test(arguments: [CreditsFailure.unavailable, .rateLimited, .unknownPack])
	func aTemporaryRefusalLeavesThePurchaseUnfinished(_ refusal: CreditsFailure) async throws {
		let (coach, credits, store, _) = try await purchaseSetup()
		credits.claimResult = .failure(refusal)
		let notice = await coach.buyCredits(Self.offer, in: store)
		#expect(
			sentence(notice)
				== "Your purchase went through, but the Credits weren't added yet. The app tries again the next time it opens."
		)
		#expect(notice?.actions == [])
		#expect(store.finished.isEmpty)
		#expect(store.unfinished.map(\.id) == [1])
	}

	@Test func noConnectionIsATemporaryRefusal() async throws {
		let worker = try #require(URL(string: "https://credits.test"))
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [OfflineURLProtocol.self]
		let session = URLSession(configuration: configuration)
		let (coach, _, store, _) = try await purchaseSetup(
			service: CreditsService {
				PhoneCreditsClient(vault: $0, workerBase: worker, session: session)
			})
		let notice = await coach.buyCredits(Self.offer, in: store)
		#expect(notice?.key == Catalog.creditsPurchaseNotAdded)
		#expect(store.finished.isEmpty)
		#expect(store.unfinished.map(\.id) == [1])
	}

	@Test(arguments: [
		CreditsFailure.banned, .athleteDeleted, .identityMismatch, .notOurBundle,
		.wrongEnvironment,
	])
	func aPermanentRefusalFinishesAndOffersAppleRefund(_ refusal: CreditsFailure) async throws {
		let (coach, credits, store, _) = try await purchaseSetup()
		credits.claimResult = .failure(refusal)
		let notice = await coach.buyCredits(Self.offer, in: store)
		#expect(
			sentence(notice)
				== "Your purchase went through, but the Credits can't be added. You can ask Apple for a refund."
		)
		#expect(notice?.actions == [.askAppleForRefund(1)])
		#expect(store.finished == [1])
	}

	@Test func aPurchaseWithoutTheCreditsIdIsRefusedWithoutAClaim() async throws {
		let (coach, credits, store, _) = try await purchaseSetup()
		let purchase = CreditsPurchase(
			id: 7, signedTransaction: "fake.signed.offer-code", appAccountToken: nil,
			purchaseDate: Date(timeIntervalSince1970: 0), isRefunded: false)
		let notice = await coach.settleCreditsPurchase(purchase, in: store)
		#expect(notice?.actions == [.askAppleForRefund(7)])
		#expect(store.finished == [7])
		#expect(credits.calls.isEmpty)
	}

	@Test func aRefundedPurchaseFinishesWithoutAClaimOrNotice() async throws {
		let (coach, credits, store, _) = try await purchaseSetup()
		let purchase = CreditsPurchase(
			id: 9, signedTransaction: "fake.signed.refunded", appAccountToken: UUID(),
			purchaseDate: Date(timeIntervalSince1970: 0), isRefunded: true)
		#expect(await coach.settleCreditsPurchase(purchase, in: store) == nil)
		#expect(store.finished == [9])
		#expect(credits.calls.isEmpty)
	}

	@Test func addedCreditsDoNotDependOnReadingTheCreditsKeyAfterTheClaim() async throws {
		let backing = FixtureSecretStoreBacking()
		let credits = FakeCreditsClient()
		credits.claimResult = .success(.toppedUp(creditsAdded: Credits(units: 401)))
		let (coach, _, store, _) = try await purchaseSetup(
			service: CreditsService { _ in
				KeychainFailsDuringClaim(fake: credits, backing: backing)
			},
			backing: backing)
		let purchase = CreditsPurchase(
			id: 3, signedTransaction: "fake.signed.locked", appAccountToken: UUID(),
			purchaseDate: Date(timeIntervalSince1970: 0), isRefunded: false)
		#expect(
			await coach.settleCreditsPurchase(purchase, in: store)?.canonicalSentence
				== "Added 401 credits")
		#expect(store.finished == [3])
	}

	@Test func aClaimThatAddsNothingBecauseOfAnEarlierRefundFinishesQuietly() async throws {
		let (coach, credits, store, _) = try await purchaseSetup()
		credits.claimResult = .success(.toppedUp(creditsAdded: Credits(units: 0)))
		#expect(await coach.buyCredits(Self.offer, in: store) == nil)
		#expect(store.finished == [1])
	}

	@Test(arguments: [
		(ClaimOutcome.toppedUp(creditsAdded: Credits(units: 401)), String?("Added 401 credits")),
		(.toppedUp(creditsAdded: Credits(units: 0)), nil),
		(.alreadyClaimed, nil),
	])
	func aClaimOnARecordThePhoneHasNoKeyForRecoversTheKeyBeforeFinishing(
		_ outcome: ClaimOutcome, _ expected: String?
	) async throws {
		let (coach, credits, store, secrets) = try await purchaseSetup(
			hasKey: false, mintedKey: Self.recordKey)
		let record = UUID()
		credits.claimResult = .success(outcome)
		credits.recoverResult = .success(Recovery(athleteId: record, credits: Credits(units: 601)))
		#expect(sentence(await coach.buyCredits(Self.offer, in: store)) == expected)
		#expect(
			try secrets.creditsAccount()
				== CreditsAccount(appAccountToken: record, key: Self.recordKey))
		#expect(store.finished == [1])
	}

	@Test(
		arguments: [
			ClaimOutcome.toppedUp(creditsAdded: Credits(units: 401)),
			.toppedUp(creditsAdded: Credits(units: 0)), .alreadyClaimed,
		], [CreditsFailure.unavailable, .banned])
	func aClaimOnARecordThePhoneHasNoKeyForStaysUnfinishedWhenTheRecoverFails(
		_ outcome: ClaimOutcome, _ failure: CreditsFailure
	) async throws {
		let (coach, credits, store, secrets) = try await purchaseSetup(
			hasKey: false, mintedKey: Self.recordKey)
		credits.claimResult = .success(outcome)
		credits.recoverResult = .failure(failure)
		let notice = await coach.buyCredits(Self.offer, in: store)
		#expect(notice?.key == Catalog.creditsPurchaseNotAdded)
		#expect(store.finished.isEmpty)
		#expect(store.unfinished.map(\.id) == [1])
		#expect(try secrets.creditsAccount()?.key == nil)
	}

	@Test(arguments: [FakeStoreAnswer.pending, .canceled, .failed])
	func anUnpaidPurchaseClaimsNothing(_ answer: FakeStoreAnswer) async throws {
		let (coach, credits, store, _) = try await purchaseSetup()
		store.answer = answer
		let notice = await coach.buyCredits(Self.offer, in: store)
		switch answer {
		case .pending:
			#expect(
				sentence(notice)
					== "Apple is still processing this purchase. The Credits are added when it's done."
			)
		case .canceled:
			#expect(notice == nil)
		case .failed, .purchased:
			#expect(sentence(notice) == "The purchase didn't finish.")
		}
		#expect(credits.calls.isEmpty)
		#expect(store.finished.isEmpty)
	}

	@Test func offersListOnlyPricedPacksWhilePurchasesAreEnabled() async throws {
		let (coach, credits, store, _) = try await purchaseSetup()
		let packs = [Self.small, Self.large]
		credits.catalogResult = .success(
			PackCatalog(purchasesEnabled: true, scale: CreditScale(creditsPerUsd: 80), packs: packs)
		)
		#expect(await coach.creditsOffers(in: store) == [Self.offer])
		credits.catalogResult = .success(
			PackCatalog(
				purchasesEnabled: false, scale: CreditScale(creditsPerUsd: 80), packs: packs))
		#expect(await coach.creditsOffers(in: store).isEmpty)
		credits.catalogResult = .failure(.unavailable)
		#expect(await coach.creditsOffers(in: store).isEmpty)
		credits.catalogResult = .success(
			PackCatalog(purchasesEnabled: true, scale: CreditScale(creditsPerUsd: 80), packs: packs)
		)
		store.prices = .failure(.pricesUnavailable)
		#expect(await coach.creditsOffers(in: store).isEmpty)
	}

	@Test(arguments: [
		Result<RefundRequest, FakeStoreFailure>.success(.submitted), .success(.canceled),
		.failure(.refundFailed),
	])
	func aRefundRequestReportsApplesAnswer(_ answer: Result<RefundRequest, FakeStoreFailure>)
		async throws
	{
		let (coach, _, store, _) = try await purchaseSetup()
		store.refundAnswer = answer
		let expected: RefundRequest? =
			switch answer {
			case .success(let request): request
			case .failure: nil
			}
		#expect(await coach.requestCreditsRefund(for: 4, in: store) == expected)
		#expect(store.refundRequests == [4])
	}

	private func sentence(_ notice: AthleteNotice?) -> String? {
		notice?.canonicalSentence
	}

	private func purchaseSetup(
		hasKey: Bool = true, mintedKey: String? = nil, service: CreditsService? = nil,
		backing: FixtureSecretStoreBacking = FixtureSecretStoreBacking()
	) async throws -> (
		Coach, FakeCreditsClient, FakeCreditsStore, ICloudKeychainStore
	) {
		let secrets =
			hasKey ? keyedSecrets(backing: backing) : ICloudKeychainStore(backing: backing)
		let credits = FakeCreditsClient()
		let store = FakeCreditsStore(prices: [Self.small.id: "$4.99"])
		let coach = await consentingCoach(
			Coach(
				sport: .cycling,
				ports: CoachPorts(
					records: RecordStore(log: InMemoryRecordLog()), secrets: secrets,
					models: .scripted(FakeModelTransport()),
					training: .fake { _, _ in FakeIntervalsClient(athleteName: "Ada", ftp: 250) },
					credits: service ?? .fake(credits, mintedKey: mintedKey),
					host: ImmediateExecutionHost(),
					clock: FixedClock(
						now: "1998-06-13T08:00:00+02:00", timeZone: "Europe/Amsterdam"),
					support: .inMemory(app: .fixture)),
				builtInModel: testModel, displayLocale: testDisplayLocale))
		return (coach, credits, store, secrets)
	}
}

private struct KeychainFailsDuringClaim: CreditsClient {
	let fake: FakeCreditsClient
	let backing: FixtureSecretStoreBacking

	func claim(signedTransaction: String, appAccountToken: UUID) async throws -> ClaimOutcome {
		backing.fail(CredentialSlot.creditsAccount.rawValue, with: errSecInteractionNotAllowed)
		return try await fake.claim(
			signedTransaction: signedTransaction, appAccountToken: appAccountToken)
	}

	func grant(deviceCheck: Data) async throws -> GrantOutcome {
		try await fake.grant(deviceCheck: deviceCheck)
	}

	func recover(signedTransaction: String) async throws -> Recovery {
		try await fake.recover(signedTransaction: signedTransaction)
	}

	func catalog() async throws -> PackCatalog { try await fake.catalog() }

	func balance() async throws -> CreditBalance { try await fake.balance() }

	func erase() async throws { try await fake.erase() }
}

private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
	}

	override func stopLoading() {}
}
