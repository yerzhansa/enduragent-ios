import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

extension FixtureLaunchTests {
	@Test func theCreditsScreenSellsEachPackAndAddsTheBoughtCredits() async throws {
		let model = await model(try services())
		let fixture = try #require(model.services.fixture)
		await model.agreeAndStartChatting()
		model.open(.credits)
		await model.loadCredits()
		let offers = try #require(model.creditOffers)
		#expect(
			offers.map(model.creditsPackLine) == [
				"401 credits · $4.99", "802 credits · $9.99", "1,606 credits · $19.99",
			])
		await model.buyCredits(offers[0])
		#expect(
			model.creditsPurchaseNotice?.sentence(in: model.displayLocale) == "Added 401 credits")
		#expect(model.balance?.units == 601)
		#expect(fixture.store.finished == [1])
		#expect(model.purchasingCredits == nil)
	}

	@Test(arguments: [true, false])
	func anApprovedAskToBuyAddsCreditsAndSaysSoOnlyOnTheOpenCreditsScreen(screenOpen: Bool)
		async throws
	{
		let model = await model(try services())
		let fixture = try #require(model.services.fixture)
		await model.agreeAndStartChatting()
		model.open(.credits)
		await model.loadCredits()
		fixture.store.answer = .pending
		await model.buyCredits(try #require(model.creditOffers?.first))
		#expect(
			model.creditsPurchaseNotice?.sentence(in: model.displayLocale)
				== "Apple is still processing this purchase. The Credits are added when it's done.")
		if !screenOpen { model.navigation.removeAll() }
		let token = try #require(try fixture.secrets.creditsAccount()?.appAccountToken)
		fixture.store.approve(FirstWeekFixture.packs[0].id, appAccountToken: token)
		try await until { fixture.store.finished == [1] && model.balance?.units == 601 }
		if !screenOpen {
			model.open(.credits)
			await model.loadCredits()
		}
		#expect(
			model.creditsPurchaseNotice?.sentence(in: model.displayLocale)
				== (screenOpen ? "Added 401 credits" : nil))
		#expect(model.balance?.units == 601)
	}

	@Test func aRefusedPurchaseOffersAppleRefundSheetFromTheCreditsScreen() async throws {
		let model = await model(try services())
		let fixture = try #require(model.services.fixture)
		fixture.credits.claimResult = .failure(.banned)
		await model.agreeAndStartChatting()
		model.open(.credits)
		await model.loadCredits()
		await model.buyCredits(try #require(model.creditOffers?.first))
		let notice = try #require(model.creditsPurchaseNotice)
		#expect(
			notice.actions.map { model.phrasebook.say($0.title, [:]) } == ["Ask Apple for a refund"]
		)
		#expect(fixture.store.finished == [1])
		fixture.store.refundAnswer = .success(.canceled)
		await model.perform(try #require(notice.actions.first))
		#expect(model.creditsPurchaseNotice == notice)
		fixture.store.refundAnswer = .success(.submitted)
		await model.perform(try #require(notice.actions.first))
		#expect(fixture.store.refundRequests == [1, 1])
		#expect(model.creditsPurchaseNotice == nil)
		#expect(model.balance?.units == 200)
	}
}
