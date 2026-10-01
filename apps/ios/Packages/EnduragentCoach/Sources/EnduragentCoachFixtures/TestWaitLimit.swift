import Foundation

public enum TestWaitLimit: Sendable {
	case hangGuard
	case subject(Duration)

	public var duration: Duration {
		switch self {
		case .hangGuard: .seconds(30)
		case .subject(let duration): duration
		}
	}
}
