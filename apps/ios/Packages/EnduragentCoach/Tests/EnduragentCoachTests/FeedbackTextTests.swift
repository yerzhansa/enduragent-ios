import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct FeedbackTextTests {
	static let javaScriptTrims: [(String, String)] = [
		("  the lap table is cut off  ", "the lap table is cut off"),
		("\u{FEFF}\u{2028}note\u{2029}\r\n", "note"),
		(
			"\t\u{000B}\u{000C}\u{00A0}\u{1680}\u{2000}\u{200A}\u{202F}\u{205F}\u{3000}note\u{3000}",
			"note"
		),
		("\u{0085}note\u{0085}", "\u{0085}note\u{0085}"),
		("\u{200B}note\u{180E}", "\u{200B}note\u{180E}"),
		("keep  the\ninside", "keep  the\ninside"),
	]

	@Test(arguments: javaScriptTrims)
	func textIsTrimmedAsJavaScriptTrims(_ raw: String, _ trimmed: String) throws {
		#expect(try FeedbackText(validating: raw).trimmed == trimmed)
	}

	static let atTheLimit: [String] = [
		String(repeating: "a", count: 4_000),
		String(repeating: "😀", count: 2_000),
		"\u{FEFF}  " + String(repeating: "a", count: 4_000) + "\n\u{3000}",
	]

	@Test(arguments: atTheLimit)
	func aTextOfFourThousandUnitsPasses(_ raw: String) throws {
		#expect(try FeedbackText(validating: raw).trimmed.utf16.count == 4_000)
	}

	static let refusals: [(String, FeedbackRefusal)] = [
		("", .empty),
		(" \u{FEFF}\n\u{2028}\u{3000} ", .empty),
		("\u{0000}", .containsNul),
		("  note\u{0000}  ", .containsNul),
		(String(repeating: "a", count: 4_001) + "\u{0000}", .containsNul),
		(String(repeating: "a", count: 4_001), .tooLong(units: 4_001)),
		(String(repeating: "😀", count: 2_000) + "a", .tooLong(units: 4_001)),
	]

	@Test(arguments: refusals)
	func aRefusedTextNamesItsFirstReason(_ raw: String, _ refusal: FeedbackRefusal) {
		#expect(throws: refusal) { try FeedbackText(validating: raw) }
	}

	@Test func mintedIdsAreLowercaseVersionFourUUIDs() throws {
		let text = try FeedbackText(validating: "the lap table is cut off")
		let ids = (0..<64).map { _ in FeedbackNote.first(text).id.rawValue }
		for id in ids {
			#expect(
				id.wholeMatch(
					of: /[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/)
					!= nil)
		}
		#expect(Set(ids).count == ids.count)
	}

	@Test func aStoredIdOnTheWorkerPatternDecodes() throws {
		let raw = "3f2a0c1e-8b4d-4c2a-9f1e-0123456789ab"
		#expect(try Self.decodedID(raw).rawValue == raw)
	}

	static let idsOffTheWorkerPattern: [String] = [
		"3F2A0C1E-8B4D-4C2A-9F1E-0123456789AB",
		"3f2a0c1e-8b4d-1c2a-9f1e-0123456789ab",
		"3f2a0c1e-8b4d-4c2a-cf1e-0123456789ab",
		"3f2a0c1e8b4d4c2a9f1e0123456789ab",
		"3f2a0c1e-8b4d-4c2a-9f1e-0123456789ab\n",
		" 3f2a0c1e-8b4d-4c2a-9f1e-0123456789ab",
		"",
	]

	@Test(arguments: idsOffTheWorkerPattern)
	func aStoredIdOffTheWorkerPatternIsRefused(_ raw: String) {
		#expect(throws: DecodingError.self) { try Self.decodedID(raw) }
	}

	@Test func revisingToTheSameTextKeepsTheNoteAndItsId() throws {
		let note = FeedbackNote.first(try FeedbackText(validating: "the lap table is cut off"))
		let resent = note.revised(to: try FeedbackText(validating: "  the lap table is cut off\n"))
		#expect(resent == note)
		#expect(resent.id == note.id)
	}

	@Test func revisingToAnotherTextMintsAnotherId() throws {
		let note = FeedbackNote.first(try FeedbackText(validating: "the lap table is cut off"))
		let edited = note.revised(
			to: try FeedbackText(validating: "the lap table is cut off on iPad"))
		#expect(edited.id != note.id)
		#expect(edited.text.trimmed == "the lap table is cut off on iPad")
	}

	static let refusedKeptTexts: [String] = [
		"",
		" \u{FEFF}\u{2028} ",
		"note\u{0000}",
		String(repeating: "a", count: 4_001),
	]

	@Test(arguments: refusedKeptTexts)
	func decodingAKeptNoteRunsTheTextChecksAgain(_ text: String) throws {
		let note = FeedbackNote.first(try FeedbackText(validating: "the lap table is cut off"))
		let accepted = try JSONEncoder().encode(["id": note.id.rawValue, "text": note.text.trimmed])
		#expect(try JSONDecoder().decode(FeedbackNote.self, from: accepted) == note)
		let refused = try JSONEncoder().encode(["id": note.id.rawValue, "text": text])
		#expect(throws: DecodingError.self) {
			try JSONDecoder().decode(FeedbackNote.self, from: refused)
		}
	}

	@Test func theBodyHoldsExactlyChannelIdAndText() throws {
		let note = FeedbackNote.first(try FeedbackText(validating: "  the lap table is cut off \n"))
		let encoded = try JSONEncoder().encode(FeedbackBody(note))
		let body = try JSONValue.parse(String(decoding: encoded, as: UTF8.self))
		#expect(Set(body.objectFields.keys) == ["channel", "id", "text"])
		#expect(body.objectFields["channel"]?.stringValue == "ios")
		#expect(body.objectFields["id"]?.stringValue == note.id.rawValue)
		#expect(body.objectFields["text"]?.stringValue == "the lap table is cut off")
	}

	private static func decodedID(_ raw: String) throws -> FeedbackID {
		try JSONDecoder().decode(FeedbackID.self, from: try JSONEncoder().encode(raw))
	}
}
