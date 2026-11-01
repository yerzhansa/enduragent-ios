import Foundation

package enum TurnEnding: Equatable, Sendable {
	case finished
	case abandoned
	case processEnded

	package init(_ settlement: Settlement) {
		switch settlement {
		case .replied: self = .finished
		case .interrupted(_, .processEnded, _): self = .processEnded
		case .savedWork, .failed, .interrupted: self = .abandoned
		}
	}
}
