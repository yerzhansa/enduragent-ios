#if os(macOS)
	import Foundation
	import Testing

	@testable import EnduragentCoach

	@Suite(.serialized) struct LiveReadsCheck {
		@Test(.enabled(if: LiveCheck.selected == .reads), .timeLimit(.minutes(10)))
		func readsTheKeyOwnerThroughTheAppsReadCode() async throws {
			let started = Date()
			let key: String
			do {
				key = try #require(
					try LiveKey.secrets([.intervals], lookUp: LiveKey.lookUpInKeychain)[.intervals])
			} catch let stop as LiveCheckStop {
				Issue.record(Comment(rawValue: stop.description))
				return
			}
			var run = LiveReadsRun(
				folder: try LiveRunFolder(kind: .reads, startedAt: started),
				client: IntervalsRESTClient(
					credential: .apiKey(key), session: LiveResponseTap.session()),
				today: IntervalsPolicy.today(now: started, timeZone: .current))
			await run.readEverything()
			try run.writeFindings()
			for failure in run.failures {
				Issue.record(Comment(rawValue: failure))
			}
		}
	}

	struct LiveReadsRun {
		static let unknownChannel = "enduragent_unknown_channel"

		let folder: LiveRunFolder
		let client: IntervalsRESTClient
		let today: CivilDate
		private(set) var failures: [String] = []
		private(set) var raw = LiveRawReads()
		private var index: [String] = ["file\tmethod\tpath\tquery\tstatus\tbytes"]
		private var snapshot = ""

		init(folder: LiveRunFolder, client: IntervalsRESTClient, today: CivilDate) {
			self.folder = folder
			self.client = client
			self.today = today
		}

		mutating func readEverything() async {
			raw.profile = await read("profile", audit: LiveReadAudit.profile) { [client] in
				CoachReadout.profile(try await client.profile())
			}?.json
			raw.wellness = await read(
				"wellness-14-days", audit: LiveReadAudit.wellness
			) { [client, today] in
				let range = try ReadRange(
					oldest: today.adding(days: -13), newest: today, today: today)
				return CoachReadout.wellness(try await client.wellness(in: range), in: range)
			}?.json
			var listing: ActivityListing?
			raw.activities = await read(
				"activities-30-days", audit: LiveReadAudit.activities
			) { [client, today] in
				let range = try ReadRange(
					oldest: today.adding(days: -29), newest: today, today: today)
				let read = try await client.activities(in: range)
				listing = read
				return CoachReadout.activities(read)
			}?.json
			let newest = (listing?.activities ?? []).sorted(by: Self.newerFirst)
			for (position, activity) in newest.prefix(3).enumerated() {
				await readDetail(activity.id, as: "activity-\(position + 1)")
			}
			if let hidden = (raw.activities?.arrayValue ?? []).map(\.objectFields).first(
				where: LiveReadAudit.isHiddenByStrava),
				let id = LiveReadAudit.identifier(hidden["id"]).flatMap(ActivityID.init(rawValue:))
			{
				await readDetail(id, as: "activity-hidden-by-strava")
			}
			if let ride = newest.first(where: {
				$0.sport.map(IntervalsPolicy.cyclingSports.contains) ?? false
			}) {
				await readStreams(of: ride.id)
			}
			await readSnapshot()
		}

		mutating func writeFindings() throws {
			try folder.write(index.joined(separator: "\n") + "\n", to: "raw/index.tsv")
			let answers = LiveParkedQuestions.answers(raw)
			let lines =
				[
					"# Live reads \(folder.run.lastPathComponent)", "",
					"Today on this Mac: \(today.rawValue)", "",
					"## Failures", "",
				] + (failures.isEmpty ? ["None."] : failures.map { "- \($0)" }) + [
					"", "## Training snapshot as the coach is given it", "", "```", snapshot, "```",
					"",
				] + answers.map(\.markdown)
			try folder.write(lines.joined(separator: "\n"), to: "findings.md")
		}

		private mutating func readDetail(_ id: ActivityID, as name: String) async {
			if let response = await read(
				name, audit: LiveReadAudit.activity,
				{ [client] in
					CoachReadout.activity(try await client.activity(id), asked: id)
				}), let json = response.json
			{
				raw.details.append(json)
			}
		}

		private mutating func readStreams(of id: ActivityID) async {
			let standard = StreamChannels.standard
			raw.askedChannels = standard.names
			raw.streams = await read("streams", audit: LiveReadAudit.streams) { [client] in
				CoachReadout.streams(try await client.streams(of: id, channels: standard))
			}
			let asked = StreamChannels(requested: ["watts", Self.unknownChannel])
			raw.unknownChannelName = Self.unknownChannel
			raw.unknownChannel = await read("streams-unknown-channel", audit: LiveReadAudit.streams)
			{ [client] in
				CoachReadout.streams(try await client.streams(of: id, channels: asked))
			}
		}

		private mutating func readSnapshot() async {
			let clock = SystemClock()
			let reader = TrainingSnapshotReader(
				clock: clock, deadlineSleep: clock.sleep, diagnostics: DiagnosticsLog(clock: clock))
			let training = TrainingConnection.connected(
				ConnectedTraining(connection: ConnectionID(), athlete: nil, client: client))
			do {
				let read = try await reader.snapshot(
					for: training, attempt: AttemptID(ulid: ULID.generate(at: clock.now)))
				snapshot = read.promptSection
				if case .unavailable(let gap) = read {
					failures.append("snapshot: the coach is given no lines (\(gap))")
				}
			} catch {
				failures.append("snapshot: the read was cancelled")
			}
			failures += LiveReadAudit.snapshotOutOfRange(snapshot)
			save(LiveResponseTap.drain(), as: "snapshot")
			record { [folder, snapshot] in
				try folder.write(snapshot + "\n", to: "given/snapshot.md")
			}
		}

		private mutating func read(
			_ name: String, audit: (JSONValue, JSONValue) -> [String],
			_ read: () async throws -> JSONValue
		) async -> TappedResponse? {
			let given: JSONValue
			do {
				given = try await read()
			} catch let error as IntervalsError {
				failures.append("\(name): the read threw \(error.code): \(error.details)")
				save(LiveResponseTap.drain(), as: name)
				return nil
			} catch {
				failures.append("\(name): the read threw \(String(describing: error))")
				save(LiveResponseTap.drain(), as: name)
				return nil
			}
			let responses = LiveResponseTap.drain()
			save(responses, as: name)
			record { [folder] in try folder.write(json: given, to: "given/\(name).json") }
			guard let response = responses.last else {
				failures.append("\(name): no raw response was captured")
				return nil
			}
			switch response.parsed {
			case .success(let json):
				failures += audit(json, given)
			case .failure(let error):
				failures.append("\(name): the raw response is not JSON (\(error))")
			}
			return response
		}

		private mutating func save(_ responses: [TappedResponse], as name: String) {
			for (position, response) in responses.enumerated() {
				let file =
					"raw/\(index.count)-\(name)\(responses.count > 1 ? "-\(position + 1)" : "").json"
				record { [folder] in try folder.write(response.body, to: file) }
				index.append(
					[
						file, response.method, response.path, response.query ?? "",
						String(response.status), String(response.body.count),
					].joined(separator: "\t"))
			}
		}

		private mutating func record(_ write: () throws -> Void) {
			do {
				try write()
			} catch {
				failures.append("could not write the run folder: \(error.localizedDescription)")
			}
		}

		static func newerFirst(_ first: Activity, _ second: Activity) -> Bool {
			(first.start.date, first.start.secondOfDay ?? -1)
				> (second.start.date, second.start.secondOfDay ?? -1)
		}
	}
#endif
