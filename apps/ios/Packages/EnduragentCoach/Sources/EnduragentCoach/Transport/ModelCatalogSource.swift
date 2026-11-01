import Foundation

package protocol ModelCatalogSource: Sendable {
	func download() async throws -> Data
}

package struct HTTPModelCatalogSource: ModelCatalogSource {
	private let session: URLSession
	private static let endpoint: URL = {
		guard let url = URL(string: "https://api.enduragent.icu/models/ios/v1/catalog.json") else {
			fatalError("The model catalog URL is invalid")
		}
		return url
	}()

	package init(session: URLSession = ephemeralSession(requestTimeout: 30, resourceTimeout: 30)) {
		self.session = session
	}

	package func download() async throws -> Data {
		let (data, response) = try await session.data(from: Self.endpoint)
		guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
			throw CatalogIssue.offline
		}
		return data
	}
}
