import Foundation

extension Memory {
	func executeMemoryWrite(_ arguments: JSONValue, source: LedgerSource, stamp: OperationStamp)
		async throws
		-> ToolExecution
	{
		let fields = arguments.objectFields
		let type = fields["type"]?.stringValue
		let content = fields["content"]?.stringValue ?? ""
		if source == .flush || type == "memory" {
			guard let section = fields["section"]?.stringValue,
				source == .chat || fields["content"]?.stringValue != nil
			else {
				return .result(
					.object([
						"details": .string(
							"type='memory' requires a section. Pick one of the listed sections, or use type='daily' for free-form notes."
						),
						"error": .string("section_required"),
					])
				)
			}
			let view = try await view()
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
		guard
			let dateRaw = fields["date"]?.stringValue,
			let date = CivilDate(rawValue: dateRaw),
			let kindRaw = fields["kind"]?.stringValue,
			let kind = LedgerKind(rawValue: kindRaw),
			let text = fields["text"]?.stringValue,
			!text.isEmpty
		else {
			let dateRaw = fields["date"]?.stringValue ?? ""
			return .result(
				.string("Error: \(dateRaw) is not a real calendar date. Use YYYY-MM-DD."))
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
