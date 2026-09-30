import Foundation

package func ephemeralSession(
	requestTimeout: TimeInterval, resourceTimeout: TimeInterval? = nil
) -> URLSession {
	let configuration = URLSessionConfiguration.ephemeral
	configuration.urlCache = nil
	configuration.timeoutIntervalForRequest = requestTimeout
	if let resourceTimeout {
		configuration.timeoutIntervalForResource = resourceTimeout
	}
	return URLSession(configuration: configuration)
}
