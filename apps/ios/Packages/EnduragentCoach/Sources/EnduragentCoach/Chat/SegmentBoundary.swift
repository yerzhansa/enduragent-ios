import Foundation

package enum SegmentBoundary: Sendable, Equatable {
	case legacy(ULID, recorded: HybridLogicalClock)
	case observed(HybridLogicalClock)

	func includes(_ ulid: ULID, at hlc: HybridLogicalClock) -> Bool {
		switch self {
		case .legacy(let boundary, _): ulid >= boundary
		case .observed(let boundary): hlc >= boundary
		}
	}

	func precedes(_ other: SegmentBoundary) -> Bool {
		switch (self, other) {
		case (.legacy(let lhs, _), .legacy(let rhs, _)): lhs < rhs
		default: clock < other.clock
		}
	}

	private var clock: HybridLogicalClock {
		switch self {
		case .legacy(_, let recorded): recorded
		case .observed(let boundary): boundary
		}
	}
}

package struct ReservedReset: Sendable, Equatable {
	package let id: ResetID
	package let boundary: HybridLogicalClock
}
