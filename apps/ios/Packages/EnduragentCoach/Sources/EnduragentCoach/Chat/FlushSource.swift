import Foundation

package enum FlushSource: Sendable, Equatable {
	case bound(ActionBinding)
	case recoverFromRows

	func sharesOwner(with other: FlushSource) -> Bool {
		switch (self, other) {
		case (.bound(let source), .bound(let older)):
			return source.account.authority(under: older.account) == .same
				|| source.account.authority(under: older.account) == .sameAthlete
		case (.recoverFromRows, .recoverFromRows):
			return true
		default:
			return false
		}
	}
}

package struct OwnedFlushRows: Sendable {
	package let binding: ActionBinding
	package let rows: [ConversationRow]

	private init(binding: ActionBinding, rows: [ConversationRow]) {
		self.binding = binding
		self.rows = rows
	}

	package static func partition(
		_ rows: [ConversationRow], using ownership: InformationOwnership, jobDevice: DeviceID,
		zone: IANATimeZone
	) -> [OwnedFlushRows] {
		var partitions: [OwnedFlushRows] = []
		var seen: Set<ULID> = []
		for row in rows where seen.insert(row.ulid).inserted {
			let binding = ownership.sourceBinding(
				for: row.account, jobDevice: jobDevice, zone: zone)
			if let index = partitions.firstIndex(where: {
				FlushSource.bound($0.binding).sharesOwner(with: .bound(binding))
			}) {
				partitions[index] = OwnedFlushRows(
					binding: partitions[index].binding, rows: partitions[index].rows + [row])
			} else {
				partitions.append(OwnedFlushRows(binding: binding, rows: [row]))
			}
		}
		return partitions
	}
}
