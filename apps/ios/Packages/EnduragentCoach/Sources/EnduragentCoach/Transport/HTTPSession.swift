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
