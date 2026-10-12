import Foundation

extension Memory {
	func loadSnapshot(for account: TrainingAccount) async throws -> MemorySnapshot {
		try await loadSnapshot(for: account, originating: nil)
	}

	func loadSnapshot(for stamp: OperationStamp) async throws -> MemorySnapshot {
		try await loadSnapshot(for: stamp.binding.account, originating: stamp)
	}

	private func loadSnapshot(for account: TrainingAccount, originating stamp: OperationStamp?)
		async throws -> MemorySnapshot
	{
		let records = try await ledger.read(RecordQuery(scope: Self.snapshotScope)).records
		let ownership = try await ledger.informationOwnership()
		let selected =
			stamp.map {
				ownership.extractionReadAccount(for: $0, origin: ledger.deviceId)
			} ?? account
		let scope = ownership.scope(for: selected, device: ledger.deviceId)
		let owned = records.filter {
			scope.contains(
				ownership.memoryOwner(
					account: ownership.recoveredMemoryAccount(of: $0), origin: $0.deviceId))
		}
		return MemorySnapshotReader(records: owned).snapshot
	}
}

private struct MemorySnapshotReader {
	let records: [AthleteRecord]

	var snapshot: MemorySnapshot {
		var sections: [AthleteRecord] = []
		var daily: [AthleteRecord] = []
		var events: [AthleteRecord] = []
		var journal: [AthleteRecord] = []
		var compaction: [AthleteRecord] = []
		for record in records {
			switch record.body {
			case .synced(.memorySection): sections.append(record)
			case .synced(.dailyNote): daily.append(record)
			case .synced(.ledgerEvent): events.append(record)
			case .synced(.journal): journal.append(record)
			case .synced(.compactionSummary): compaction.append(record)
			default: break
			}
		}
		return MemorySnapshot(
			sections: sections, daily: daily, ledgerRecords: UnionMerge.ledger(events),
			journalRecords: journal, compaction: compaction, orphanNames: orphanNames(in: sections))
	}

	private func orphanNames(in sections: [AthleteRecord]) -> [String] {
		let declared = SectionName.declaredNames
		var seen: Set<String> = []
		var names: [String] = []
		for record in sections.sorted(by: { $0.hlc < $1.hlc }) {
			guard case .synced(.memorySection(let body)) = record.body else { continue }
			if declared.contains(body.name.rawValue) { continue }
			if seen.insert(body.name.rawValue).inserted { names.append(body.name.rawValue) }
		}
		return names
	}
}
