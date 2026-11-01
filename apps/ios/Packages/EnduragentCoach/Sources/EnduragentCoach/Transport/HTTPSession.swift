import Foundation

package func ephemeralSession(
	requestTimeout: TimeInterval, resourceTimeout: TimeInterval? = nil,
	protocolClasses: [AnyClass]? = nil
) -> URLSession {
	let configuration = URLSessionConfiguration.ephemeral
	configuration.protocolClasses = protocolClasses
	configuration.urlCache = nil
	configuration.httpCookieStorage = nil
	configuration.httpShouldSetCookies = false
	configuration.urlCredentialStorage = nil
	configuration.timeoutIntervalForRequest = requestTimeout
	if let resourceTimeout {
		configuration.timeoutIntervalForResource = resourceTimeout
	}
	return URLSession(configuration: configuration)
}

package final class RejectRedirects: NSObject, URLSessionTaskDelegate {
	package func urlSession(
		_ session: URLSession, task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping @Sendable (URLRequest?) -> Void
	) {
		completionHandler(nil)
	}
}
