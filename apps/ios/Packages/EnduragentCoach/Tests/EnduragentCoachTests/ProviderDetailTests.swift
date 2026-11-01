import Testing

@testable import EnduragentCoach

@Suite struct ProviderDetailTests {
	@Test func anOpenRouterErrorGivesItsStatusAndNumericCode() {
		#expect(
			ProviderDetail.parse(status: 402, body: #"{"error":{"code":402,"message":"x"}}"#)
				== .http(status: 402, openRouter: .code(402)))
	}

	@Test(arguments: [
		(400, #"{"error":{"message":"Saturday's long ride hurt my knee"}}"#),
		(402, #"{"error":{"code":"402","message":"Saturday's long ride hurt my knee"}}"#),
		(400, #"{"error":{"code":400.5,"message":"Saturday's long ride hurt my knee"}}"#),
		(502, "<html><body>Saturday's long ride hurt my knee</body></html>"),
		(500, ""),
	])
	func aBodyWithoutANumericErrorCodeIsUnparsed(_ status: Int, _ body: String) {
		let detail = ProviderDetail.parse(status: status, body: body)
		#expect(detail == .http(status: status, openRouter: .unparsed))
		#expect(!String(describing: detail).contains("knee"))
	}
}
