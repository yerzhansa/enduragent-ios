import DeviceCheck
import Foundation

protocol DeviceCheckTokenProviding: Sendable {
	func token() async throws -> Data
}

struct DeviceCheckUnavailable: LocalizedError {
	var errorDescription: String? {
		"DeviceCheck is not available on this device"
	}
}

struct DeviceCheckTokenProvider: DeviceCheckTokenProviding {
	func token() async throws -> Data {
		let device = DCDevice.current
		guard device.isSupported else {
			throw DeviceCheckUnavailable()
		}
		return try await device.generateToken()
	}
}

struct FakeDeviceCheckTokenProvider: DeviceCheckTokenProviding {
	func token() async throws -> Data {
		Data([1])
	}
}
