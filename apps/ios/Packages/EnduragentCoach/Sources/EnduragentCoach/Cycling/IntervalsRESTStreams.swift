import Foundation

extension IntervalsRESTClient {
	package func streams(of id: ActivityID, channels: StreamChannels) async throws
		-> StreamSummary
	{
		var asking = channels.names
		var reported: [String: ChannelGap] = [:]
		for _ in 0..<IntervalsPolicy.streamRequestLimit where !asking.isEmpty {
			let answer = try await exchange(
				method: "GET", path: ["activity", id.rawValue, "streams.json"],
				query: [URLQueryItem(name: "types", value: asking.joined(separator: ","))])
			if let rejected = Self.rejectedStreamType(in: answer), asking.contains(rejected) {
				asking.removeAll { $0 == rejected }
				reported[rejected] = .unknown
				continue
			}
			let json = try parseJSON(try Self.accepted(answer))
			return StreamSummary(
				summarizing: try Self.streamSamples(from: json), asked: channels,
				reported: reported)
		}
		for name in asking { reported[name] = .unread }
		return StreamSummary(summarizing: [], asked: channels, reported: reported)
	}

	private static func rejectedStreamType(in answer: IntervalsAnswer) -> String? {
		let prefix = "Invalid stream type ["
		guard answer.status == 422, let text = String(data: answer.body, encoding: .utf8) else {
			return nil
		}
		let message: String?
		do {
			message = try JSONValue.parse(text).objectFields["error"]?.stringValue
		} catch is DecodingError {
			return nil
		}
		guard let message, message.hasPrefix(prefix), message.hasSuffix("]") else { return nil }
		return String(message.dropFirst(prefix.count).dropLast())
	}

	private static func streamSamples(from wire: JSONValue) throws(IntervalsError)
		-> [StreamSamples]
	{
		let sent: [(channel: String?, data: JSONValue?)]
		switch wire {
		case .array(let entries):
			sent = entries.map { ($0.objectFields["type"]?.stringValue, $0.objectFields["data"]) }
		case .object(let fields):
			sent = fields.map { ($0.key, $0.value) }
		default:
			throw IntervalsError(
				code: "invalid_json", details: "streams response was not a list or an object")
		}
		return sent.compactMap { channel, data in
			guard let channel, let slots = data?.arrayValue else { return nil }
			return StreamSamples(
				channel: channel,
				values: slots.map { slot in
					guard case .number(let value) = slot, value.isFinite else { return nil }
					return value
				})
		}
	}
}
