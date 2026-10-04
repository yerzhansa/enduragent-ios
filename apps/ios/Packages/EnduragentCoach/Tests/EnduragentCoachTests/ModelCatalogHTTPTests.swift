import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct ModelCatalogHTTPTests {
	@Test(arguments: [200, 503])
	func catalogHTTPResponseUsesTheScriptedPublisher(_ statusCode: Int) async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [CatalogURLStub.self]
		configuration.httpAdditionalHeaders = ["X-Fixture-Status": String(statusCode)]
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		let fixture = try ModelCatalogRefreshTests.Fixture()
		let coach = try await fixture.coach(source: HTTPModelCatalogSource(session: session))
		let stream = await coach.observeStatus()
		await coach.lifecycle(.becameActive)
		let cache: CatalogCacheState =
			statusCode == 200 ? .available(.downloaded) : .retained(.bundled, .offline)
		let snapshot = try #require(
			try await stream.status {
				$0.access.modelChoices?.catalog.cache == cache
			})
		let choices = try #require(snapshot.access.modelChoices)
		let model = ModelID(rawValue: "fixture/http-model")
		if statusCode == 200 {
			#expect(choices.catalog.catalog.entries[model]?.displayName == "HTTP Coach")
		} else {
			#expect(choices.catalog.catalog == .bundled)
		}
		try await fixture.proveReply(coach, model: ModelCatalog.bundled.orderedEntries[0].id)
		await coach.lifecycle(.willTerminate)
	}
}

private final class CatalogURLStub: URLProtocol, @unchecked Sendable {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		#expect(
			request.url?.absoluteString == "https://api.enduragent.icu/models/ios/v1/catalog.json")
		#expect(request.httpMethod == "GET")
		#expect(request.value(forHTTPHeaderField: "Authorization") == nil)
		guard let url = request.url,
			let code = request.value(forHTTPHeaderField: "X-Fixture-Status").flatMap(Int.init),
			let response = HTTPURLResponse(
				url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)
		else {
			client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
			return
		}
		let data = Data(
			#"{"revision":2,"entries":[{"id":"fixture/http-model","displayName":"HTTP Coach","provider":{"name":"Fixture Host","routingSlug":"fixture-host"}}]}"#
				.utf8)
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: data)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}
