#if DEBUG
	import EnduragentCoach
	import SwiftUI

	struct RecordSyncDebugView: View {
		let probe: RecordSyncProbe?
		@State private var loadError: String?
		@State private var status = ""
		@State private var snapshot: RecordSyncSnapshot?

		var body: some View {
			NavigationStack {
				List {
					Section("Device") {
						Text(snapshot?.deviceId.rawValue ?? "—")
					}
					Section("Newest HLC") {
						Text(snapshot.map { $0.newestHLC.isEmpty ? "—" : $0.newestHLC } ?? "—")
					}
					Section("Count per kind") {
						if let counts = snapshot?.counts, !counts.isEmpty {
							ForEach(counts) { item in
								HStack {
									Text(item.kind)
									Spacer()
									Text("\(item.count)")
								}
								.accessibilityIdentifier("records.count.\(item.kind)")
							}
						} else {
							Text("No records")
						}
					}
					Section("Records") {
						ForEach(snapshot?.rows ?? []) { row in
							VStack(alignment: .leading, spacing: 4) {
								Text(row.kind)
								Text(row.deviceId)
									.font(.caption)
								Text(row.hlc)
									.font(.caption2)
									.monospaced()
							}
							.accessibilityIdentifier("records.row.\(row.id)")
						}
					}
					if let skipped = snapshot?.skipped, skipped > 0 {
						Section("Skipped rows") {
							Text("\(skipped)")
						}
					}
					Section("Append") {
						Button("Append three synced records") {
							Task { await appendSynced() }
						}
						Button("Append one device-local record") {
							Task { await appendLocal() }
						}
						Button("Refresh") {
							Task { await refresh() }
						}
					}
					if let loadError {
						Section("Error") {
							Text(loadError)
						}
					} else if !status.isEmpty {
						Section("Status") {
							Text(status)
						}
					}
				}
				.navigationTitle("Record Sync")
				.task { await refresh() }
			}
		}

		@MainActor
		private func refresh() async {
			guard let probe else {
				loadError = "No coach services yet"
				return
			}
			do {
				snapshot = try await probe.snapshot()
				loadError = nil
			} catch {
				loadError = String(describing: error)
			}
		}

		@MainActor
		private func appendSynced() async {
			guard let probe else { return }
			do {
				try await probe.appendSyncedSamples()
				status = "Appended three synced records"
				await refresh()
			} catch {
				loadError = String(describing: error)
			}
		}

		@MainActor
		private func appendLocal() async {
			guard let probe else { return }
			do {
				try await probe.appendLocalSample()
				status = "Appended one device-local record"
				await refresh()
			} catch {
				loadError = String(describing: error)
			}
		}
	}
#endif
