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
					Text(summary(record))
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
			if let expiry = record.expiry {
				parts.append("expired \(expiry.rawValue)")
			}
			switch record.ending {
			case .finished?:
				parts.append("finished")
			case .failed?:
				parts.append("failed")
			case .interrupted(let cause)?:
				parts.append("interrupted \(cause.rawValue)")
			case nil:
				parts.append("open")
			}
			return parts.joined(separator: " ")
		}
	}
#endif
