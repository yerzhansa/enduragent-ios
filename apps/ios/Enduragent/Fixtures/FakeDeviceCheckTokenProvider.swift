#if DEBUG
	import Foundation

	struct FakeDeviceCheckTokenProvider: DeviceCheckTokenProviding {
		func token() async throws -> Data {
			Data([1])
		}
	}
#endif
