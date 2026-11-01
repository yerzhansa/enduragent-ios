import Foundation

package enum ConnectionLoss: Sendable, Equatable {
	case noConnection
	case unreachable

	private static let offline: Set<URLError.Code> = [
		.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
	]

	package init(_ error: URLError) {
		self = Self.offline.contains(error.code) ? .noConnection : .unreachable
	}
}
