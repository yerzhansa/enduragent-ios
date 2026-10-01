import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct WindowStartCodecTests {
	let identity = "00T5D6HS000000000000000001"

	@Test func reservedResetWindowV3RoundTripsGoldenBytes() throws {
		let json =
			"{\"boundaryClock\":{\"deviceId\":\"phone-a\",\"logical\":7,\"wallMs\":897984000000},\"chatId\":\"main\",\"firstIncludedUlid\":\"\(identity)\",\"reason\":\"reset:explicit:\(identity)\"}"
		let decoded = try decode(json, version: 3).get()
		let encoded = try RecordCodec.encode(decoded)
		#expect(encoded.version == 3)
		#expect(String(decoding: encoded.data, as: UTF8.self) == json)
	}

	@Test(arguments: ["trim", "compaction", "reset:explicit:00T5D6HS000000000000000001"])
	func oldWindowV2KeepsItsGoldenBytes(reason: String) throws {
		let json =
			"{\"chatId\":\"main\",\"firstIncludedUlid\":\"\(identity)\",\"reason\":\"\(reason)\"}"
		let decoded = try decode(json, version: 2).get()
		let encoded = try RecordCodec.encode(decoded)
		#expect(encoded.version == 2)
		#expect(String(decoding: encoded.data, as: UTF8.self) == json)
	}

	@Test(arguments: [
		#"{"chatId":"main","firstIncludedUlid":"00T5D6HS000000000000000001","reason":"reset:explicit:00T5D6HS000000000000000001"}"#,
		#"{"boundaryClock":{"deviceId":"phone-a","logical":-1,"wallMs":897984000000},"chatId":"main","firstIncludedUlid":"00T5D6HS000000000000000001","reason":"reset:explicit:00T5D6HS000000000000000001"}"#,
		#"{"boundaryClock":{"deviceId":"phone-a","logical":7,"wallMs":897984000000},"chatId":"main","firstIncludedUlid":"00T5D6HS000000000000000001","reason":"trim"}"#,
	])
	func malformedReservedWindowIsRejected(_ json: String) {
		guard case .failure = decode(json, version: 3) else {
			Issue.record("Accepted a malformed reserved reset window")
			return
		}
	}

	private func decode(_ json: String, version: Int) -> Result<RecordBody, SkippedRow> {
		RecordCodec.decode(
			kind: "windowStart", version: version, data: Data(json.utf8),
			civilDate: "1998-06-13", ulid: identity)
	}
}
