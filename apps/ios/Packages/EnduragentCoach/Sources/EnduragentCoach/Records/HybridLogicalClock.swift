import Foundation

package struct HybridLogicalClock: Sendable, Hashable, Comparable {
	package var wallMs: Int64
	package var logical: UInt32
	package var deviceId: DeviceID

	package init(wallMs: Int64, logical: UInt32, deviceId: DeviceID) {
		self.wallMs = wallMs
		self.logical = logical
		self.deviceId = deviceId
	}

	package var wallTime: Date {
		Date(timeIntervalSince1970: Double(wallMs) / 1000)
	}

	package static func tick(now: Date, deviceId: DeviceID, last: HybridLogicalClock?)
		-> HybridLogicalClock
	{
		let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
		guard let last else {
			return HybridLogicalClock(wallMs: nowMs, logical: 0, deviceId: deviceId)
		}
		let wallMs = max(nowMs, last.wallMs)
		let logical: UInt32 = wallMs == last.wallMs ? last.logical + 1 : 0
		return HybridLogicalClock(wallMs: wallMs, logical: logical, deviceId: deviceId)
	}

	package static func < (lhs: HybridLogicalClock, rhs: HybridLogicalClock) -> Bool {
		if lhs.wallMs != rhs.wallMs { return lhs.wallMs < rhs.wallMs }
		if lhs.logical != rhs.logical { return lhs.logical < rhs.logical }
		return lhs.deviceId.rawValue < rhs.deviceId.rawValue
	}
}
