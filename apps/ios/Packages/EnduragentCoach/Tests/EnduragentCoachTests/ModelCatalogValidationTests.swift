import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ModelCatalogValidationTests {
	@Test(arguments: [
		#"{"revision":0,"entries":[{"id":"test/model","displayName":"Model","provider":{"name":"Host","routingSlug":"host"}}]}"#,
		#"{"revision":1,"entries":[]}"#,
		#"{"revision":1,"entries":[{"id":"typed model","displayName":"Model","provider":{"name":"Host","routingSlug":"host"}}]}"#,
		#"{"revision":1,"entries":[{"id":"test/model\n","displayName":"Model","provider":{"name":"Host","routingSlug":"host"}}]}"#,
		#"{"revision":1,"entries":[{"id":"test/model","displayName":" ","provider":{"name":"Host","routingSlug":"host"}}]}"#,
		#"{"revision":1,"entries":[{"id":"test/model","displayName":"Model","provider":{"name":"","routingSlug":"host"}}]}"#,
		#"{"revision":1,"entries":[{"id":"test/model","displayName":"Model","provider":{"name":"Host","routingSlug":"host\n"}}]}"#,
		#"{"revision":1,"entries":[{"id":"test/model","displayName":"Model","provider":{"name":"Host","routingSlug":"*"}}]}"#,
		#"{"revision":1,"entries":[{"id":"test/model","displayName":"Model","provider":{"name":"Host","routingSlug":"host"}},{"id":"test/model","displayName":"Other","provider":{"name":"Other","routingSlug":"other"}}]}"#,
	])
	func invalidCatalogCannotOfferChoices(_ json: String) throws {
		#expect(throws: (any Error).self) { try ModelCatalog(validating: Data(json.utf8)) }
	}
}
