import DeviceCheck
import Foundation

struct DeviceCheckUnavailable: LocalizedError {
	var errorDescription: String? {
		"DeviceCheck is not available on this device"
	}
}

struct DeviceCheckTokenProvider {
	func token() async throws -> Data {
		let device = DCDevice.current
		guard device.isSupported else {
			throw DeviceCheckUnavailable()
		}
		return try await device.generateToken()
	}
}
