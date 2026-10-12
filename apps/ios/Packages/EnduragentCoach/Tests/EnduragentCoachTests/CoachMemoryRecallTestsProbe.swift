import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

enum MemoryProbe {
	static func turn(
		_ calls: [ScriptedEvent], saying prompt: String, expecting reply: String,
		using coach: Coach, transport: FakeModelTransport
	) async throws -> CompletionRequest {
		transport.respond = ScriptedReply.sequence(
			calls + [.finish(reason: .toolCalls), .text(reply), .finish(reason: .stop)],
			otherwise: { _ in ScriptedReply([.finish(reason: .stop)]) })
		#expect(replyText(try await coach.sendAndSettle(prompt)) == reply)
		return try #require(sent(.chatAttempt, by: transport).last)
	}

	static func save(
		_ arguments: [JSONValue], saying prompt: String, using coach: Coach,
		transport: FakeModelTransport
	) async throws {
		let request = try await turn(
			arguments.map {
				.toolCall(name: "memory_write", arguments: $0.canonicalDigestInput())
			}, saying: prompt, expecting: "Saved.", using: coach, transport: transport)
		let results = request.messages.filter { $0.role == .tool }
		#expect(results.count == arguments.count)
		for result in results {
			let payload = try JSONValue.parse(result.content)
			#expect(payload.objectFields["data"]?.objectFields["saved"]?.boolValue == true)
		}
	}

	static func relaunch(
		_ coach: Coach, on device: DeviceID, in directory: URL, clock: FixedClock
	) async throws -> (coach: Coach, transport: FakeModelTransport, store: SwiftDataRecordLog) {
		await coach.lifecycle(.willTerminate)
		let store = try SwiftDataSuites.makeSwiftDataLog(deviceId: device, directory: directory)
		let transport = FakeModelTransport()
		return (await makeCoach(transport: transport, store: store, clock: clock), transport, store)
	}

	static func data(in message: WireMessage) throws -> JSONValue {
		let payload = try JSONValue.parse(message.content)
		#expect(payload.objectFields["untrusted_data"]?.stringValue == UntrustedEnvelope.banner)
		return try #require(payload.objectFields["data"])
	}

	static func text(in message: WireMessage) throws -> String {
		try #require(try data(in: message).stringValue)
	}

	static func systemText(in request: CompletionRequest) throws -> String {
		try #require(request.messages.first { $0.role == .system }).content
	}

	static func athleteData(in text: String) throws -> String {
		let open = try #require(text.range(of: PromptAssembly.athleteDataOpen))
		let close = try #require(text.range(of: PromptAssembly.athleteDataClose))
		try #require(open.upperBound <= close.lowerBound)
		#expect(text.components(separatedBy: PromptAssembly.athleteDataOpen).count == 2)
		#expect(text.components(separatedBy: PromptAssembly.athleteDataClose).count == 2)
		return String(text[open.upperBound..<close.lowerBound])
	}

	static func events(in text: String) throws -> [JSONValue] {
		try text.split(separator: "\n").filter { $0.hasPrefix("event: ") }.map {
			try JSONValue.parse(String($0.dropFirst("event: ".count)))
		}
	}
}
