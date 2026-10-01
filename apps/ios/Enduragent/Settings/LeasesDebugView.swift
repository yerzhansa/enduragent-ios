#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct LeasesDebugView: View {
		let leases: (@Sendable () async -> [LeaseRecord])?
		@State private var records: [LeaseRecord] = []

		var body: some View {
			List {
				if records.isEmpty {
					Text("No leases")
				}
				ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
					VStack(alignment: .leading, spacing: 4) {
						Text(summary(record))
						ForEach(record.notes, id: \.self) { note in
							Text(note)
								.font(.caption)
						}
					}
					.accessibilityElement(children: .ignore)
					.accessibilityLabel(([summary(record)] + record.notes).joined(separator: " "))
					.accessibilityIdentifier("leases.row.\(index)")
				}
				Button("Refresh") {
					Task { await refresh() }
				}
			}
			.navigationTitle("Leases")
			.task { await refresh() }
		}

		@MainActor
		private func refresh() async {
			records = await leases?() ?? []
		}

		private func summary(_ record: LeaseRecord) -> String {
			var parts = [record.request.initiatedBy.rawValue, record.kind.rawValue]
			if let progress = record.progress {
				parts.append("settledTurns \(progress.settledTurns) of \(progress.totalTurns)")
				parts.append("step \(progress.step) of \(progress.stepLimit)")
			}
			if let expiry = record.expiry {
				parts.append("expired \(expiry.rawValue)")
			}
			switch record.ending {
			case .finished(let notice)?:
				parts.append(notice == nil ? "finished" : "finished with notice")
			case .interrupted?:
				parts.append("interrupted")
			case nil:
				parts.append("open")
			}
			return parts.joined(separator: " ")
		}
	}
#endif
