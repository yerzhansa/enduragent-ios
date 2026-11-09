import Foundation

package enum TranscriptEvent {
	case human(uuid: String, second: Int, queued: Bool, raw: String)
	case interrupt(uuid: String, second: Int)
	case compaction(uuid: String, second: Int)
}

package struct TranscriptLine: Decodable {
	struct Origin: Decodable {
		let kind: String?
	}

	struct Message: Decodable {
		let content: Content?
	}

	struct Attachment: Decodable {
		let type: String?
		let prompt: Content?
		let origin: Origin?
	}

	let type: String
	let uuid: String?
	let timestamp: String?
	let isMeta: Bool?
	let isSidechain: Bool?
	let isCompactSummary: Bool?
	let origin: Origin?
	let message: Message?
	let attachment: Attachment?

	package static let interruptMarker = "[Request interrupted by user"

	package var event: TranscriptEvent? {
		guard isSidechain != true, let uuid, let second = timestamp.flatMap(TimeText.epochSecond)
		else { return nil }
		if type == "attachment", let attachment, attachment.type == "queued_command",
			attachment.origin?.kind == "human", let prompt = attachment.prompt
		{
			return .human(uuid: uuid, second: second, queued: true, raw: prompt.text)
		}
		guard type == "user", let content = message?.content else { return nil }
		if isCompactSummary == true { return .compaction(uuid: uuid, second: second) }
		if content.blocks.contains(where: {
			$0.type == "text" && ($0.text ?? "").hasPrefix(Self.interruptMarker)
		}) {
			return .interrupt(uuid: uuid, second: second)
		}
		guard origin?.kind == "human", isMeta != true,
			!content.blocks.contains(where: { $0.type == "tool_result" })
		else { return nil }
		return .human(uuid: uuid, second: second, queued: false, raw: content.text)
	}
}

package enum Content: Decodable {
	package struct Block: Decodable {
		let type: String?
		let text: String?
	}

	case text(String)
	case blocks([Block])

	package init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let text = try? container.decode(String.self) {
			self = .text(text)
		} else {
			self = .blocks(try container.decode([Block].self))
		}
	}

	package var blocks: [Block] {
		switch self {
		case .text(let text): [Block(type: "text", text: text)]
		case .blocks(let blocks): blocks
		}
	}

	package var text: String {
		blocks.compactMap { block in
			switch block.type {
			case "text": block.text
			case "image": "[image]"
			default: nil
			}
		}.joined(separator: "\n\n")
	}
}

package enum TranscriptBytes {
	package static let timestampKey = Array(#""timestamp":""#.utf8)
	package static let userType = Array(#""type":"user""#.utf8)
	package static let attachmentType = Array(#""type":"attachment""#.utf8)
	package static let queuedCommand = Array(#""queued_command""#.utf8)
	package static let toolResult = Array(#""tool_result""#.utf8)
	package static let interrupt = Array(TranscriptLine.interruptMarker.utf8)

	package static func forEachLine(
		of path: String, _ body: (UnsafeRawBufferPointer) throws -> Void
	) throws {
		let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
		try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
			guard let base = buffer.baseAddress else { return }
			var start = 0
			while start < buffer.count {
				let end =
					memchr(base + start, 0x0A, buffer.count - start).map {
						base.distance(to: UnsafeRawPointer($0))
					} ?? buffer.count
				if end > start {
					try body(UnsafeRawBufferPointer(rebasing: buffer[start..<end]))
				}
				start = end + 1
			}
		}
	}

	package static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
		guard let base = line.baseAddress else { return false }
		return needle.withUnsafeBytes {
			memmem(base, line.count, $0.baseAddress, needle.count) != nil
		}
	}

	package static func second(of line: UnsafeRawBufferPointer) -> Int? {
		guard let base = line.baseAddress,
			let found = timestampKey.withUnsafeBytes({
				memmem(base, line.count, $0.baseAddress, timestampKey.count)
			})
		else { return nil }
		let start = base.distance(to: UnsafeRawPointer(found)) + timestampKey.count
		guard start + 19 <= line.count else { return nil }
		return TimeText.epochSecond(
			String(
				decoding: UnsafeRawBufferPointer(rebasing: line[start..<start + 19]), as: UTF8.self)
		)
	}

	package static func mayHoldEvent(_ line: UnsafeRawBufferPointer) -> Bool {
		if contains(line, attachmentType) { return contains(line, queuedCommand) }
		guard contains(line, userType) else { return false }
		return !contains(line, toolResult) || contains(line, interrupt)
	}
}

package enum TimeText {
	static let localOffset = 5 * 3_600

	package static func epochSecond(_ text: String) -> Int? {
		let units = Array(text.utf8)
		guard units.count >= 19 else { return nil }
		func number(_ range: Range<Int>) -> Int? {
			Int(String(decoding: units[range], as: UTF8.self))
		}
		guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
			let hour = number(11..<13), let minute = number(14..<16),
			let second = number(17..<19)
		else { return nil }
		var offset = 0
		if let sign = units.lastIndex(where: { $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") }
		),
			sign > 18, units.count >= sign + 6,
			let hours = number(sign + 1..<sign + 3), let minutes = number(sign + 4..<sign + 6)
		{
			offset = (hours * 3_600 + minutes * 60) * (units[sign] == UInt8(ascii: "+") ? 1 : -1)
		}
		let days = daysFromCivil(year: year, month: month, day: day)
		return days * 86_400 + hour * 3_600 + minute * 60 + second - offset
	}

	package static func local(_ second: Int) -> String {
		let shifted = second + localOffset
		let days = shifted / 86_400
		let (year, month, day) = civil(fromDays: days)
		let rest = shifted - days * 86_400
		return String(
			format: "%04d-%02d-%02d %02d:%02d", year, month, day, rest / 3_600, rest % 3_600 / 60)
	}

	private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
		let shiftedYear = month <= 2 ? year - 1 : year
		let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
		let yearOfEra = shiftedYear - era * 400
		let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
		let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
		return era * 146_097 + dayOfEra - 719_468
	}

	private static func civil(fromDays days: Int) -> (Int, Int, Int) {
		let shifted = days + 719_468
		let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
		let dayOfEra = shifted - era * 146_097
		let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
		let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
		let monthIndex = (5 * dayOfYear + 2) / 153
		let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
		let month = monthIndex + (monthIndex < 10 ? 3 : -9)
		return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
	}
}
