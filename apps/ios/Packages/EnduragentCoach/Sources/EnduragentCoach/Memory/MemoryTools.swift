import Foundation

extension LedgerSource {
	var missingSection: String {
		switch self {
		case .chat:
			"type='memory' requires a section. Pick one of the listed sections, or use type='daily' for free-form notes."
		case .flush:
			"memory_write requires a section and content. Pick one of the listed sections."
		}
	}
}

extension Memory {
	func executeMemoryWrite(
		_ arguments: JSONValue, source: LedgerSource,
		stamp: OperationStamp
	) async throws -> ToolExecution {
		let fields = arguments.objectFields
		let type = fields["type"]?.stringValue
		let content = fields["content"]?.stringValue ?? ""
		if source == .flush || type == "memory" {
			guard let section = fields["section"]?.stringValue,
				source == .chat || fields["content"]?.stringValue != nil
			else {
				return .result(
					.object([
						"details": .string(source.missingSection),
						"error": .string("section_required"),
					])
				)
			}
			let view = try await prompt(for: stamp.binding.account).view
			let allowed = Set(SectionName.cyclingEffective.map(\.rawValue) + view.orphanNames)
			if !allowed.contains(section) {
				return .result(
					.object([
						"details": .string("Unknown memory section."),
						"error": .string("unknown_section"),
					])
				)
			}
			try await writeSection(
				SectionName(rawValue: section), content: content, source: source, stamp: stamp)
			return ToolExecution(
				outcome: .result(.object(["saved": .bool(true)])),
				commit: CommittedWrite(tool: .memoryWrite))
		}
		let appended = try await appendDailyNote(content, stamp: stamp)
		return ToolExecution(
			outcome: .result(.object(["saved": .bool(true)])),
			commit: appended ? CommittedWrite(tool: .memoryWrite) : nil)
	}

	func executeLedgerAppend(_ arguments: JSONValue, source: LedgerSource, stamp: OperationStamp)
		async throws
		-> ToolExecution
	{
		let fields = arguments.objectFields
		let dateRaw = fields["date"]?.stringValue ?? ""
		guard let date = CivilDate(rawValue: dateRaw) else {
			return .result(
				.string("Error: \(dateRaw) is not a real calendar date. Use YYYY-MM-DD."))
		}
		let kindRaw = fields["kind"]?.stringValue ?? ""
		guard let kind = LedgerKind(rawValue: kindRaw) else {
			let allowed = LedgerKind.allCases.map(\.rawValue).joined(separator: ", ")
			return .result(
				.string("Error: \(kindRaw) is not an allowed kind. Use one of: \(allowed)."))
		}
		let text = fields["text"]?.stringValue ?? ""
		guard !text.isEmpty else {
			return .result(.string("Error: text is empty. Write one or two sentences."))
		}
		let recorded = try await appendEvent(
			date: date, kind: kind, text: text, source: source, stamp: stamp)
		if recorded {
			return ToolExecution(
				outcome: .result(.object(["recorded": .bool(true)])),
				commit: CommittedWrite(tool: .ledgerAppend))
		}
		return .result(.object(["duplicate": .bool(true), "recorded": .bool(false)]))
	}

}
