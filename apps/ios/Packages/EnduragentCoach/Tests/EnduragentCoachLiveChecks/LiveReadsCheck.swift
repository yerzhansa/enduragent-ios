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
			try run.writeFindings(checkingFor: key)
			for failure in run.failures {
				Issue.record(Comment(rawValue: failure))
			}
		}
	}

	struct LiveReadsRun {
		static let unknownChannel = "enduragent_unknown_channel"
		static let probedChannels = ["watts", "velocity_smooth", unknownChannel]

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
			raw.profile = await read("profile", audit: LiveReadAudit.profile) { [client, today] in
				CoachReadout.profile(try await client.profile(), on: today)
			}.answer?.json
			raw.wellness = await read(
				"wellness-14-days", audit: LiveReadAudit.wellness
			) { [client, today] in
				let range = try ReadRange(
					oldest: today.adding(days: -13), newest: today, today: today)
				return CoachReadout.wellness(try await client.wellness(in: range), in: range)
			}.answer?.json
			var listing: ActivityListing?
			raw.activities = await read(
				"activities-30-days", audit: LiveReadAudit.activities
			) { [client, today] in
				let range = try ReadRange(
					oldest: today.adding(days: -29), newest: today, today: today)
				let read = try await client.activities(in: range)
				listing = read
				return CoachReadout.activities(read)
			}.answer?.json
			let newest = (listing?.activities ?? []).sorted { $0.start > $1.start }
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
			failures += Self.uncovered(raw)
		}

		static func uncovered(_ raw: LiveRawReads) -> [String] {
			var gaps: [String] = []
			if (raw.wellness?.arrayValue ?? []).isEmpty {
				gaps.append("not covered: no wellness day in the last 14 days")
			}
			if (raw.activities?.arrayValue ?? []).isEmpty {
				gaps.append("not covered: the account has no activity in the last 30 days")
			}
			if raw.details.isEmpty {
				gaps.append("not covered: no activity detail or laps were read")
			}
			if raw.streams == nil {
				gaps.append("not covered: no ride's streams were read")
			}
			return gaps
		}

		mutating func writeFindings(checkingFor key: String) throws {
			try folder.write(index.joined(separator: "\n") + "\n", to: "raw/index.tsv")
			failures += try folder.files(containing: key).map(Self.keyLeak)
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
			failures += try folder.files(containing: key).filter { $0 == "findings.md" }.map(
				Self.keyLeak)
		}

		private static func keyLeak(_ file: String) -> String {
			"\(file): the saved file holds the intervals.icu key"
		}

		private mutating func readDetail(_ id: ActivityID, as name: String) async {
			if let json = await read(
				name, audit: LiveReadAudit.activity,
				{ [client] in
					CoachReadout.activity(try await client.activity(id), asked: id).shown
				}
			).answer?.json {
				raw.details.append(json)
			}
		}

		private mutating func readStreams(of id: ActivityID) async {
			let standard = StreamChannels.standard.names
			raw.askedChannels = standard
			raw.streams = await readChannels(standard, of: id, as: "streams").answer
			raw.unknownChannelName = Self.unknownChannel
			raw.unknownChannel = await readChannels(
				Self.probedChannels, of: id, as: "streams-unknown-channel")
		}

		private mutating func readChannels(
			_ names: [String], of id: ActivityID, as name: String
		) async -> LiveReadOutcome {
			let outcome = await read(name, audit: LiveReadAudit.streams) { [client] in
				CoachReadout.streams(
					try await client.streams(
						of: id, channels: try StreamChannels(requested: names)))
			}
			failures += LiveReadAudit.streamNames(name, asked: names, outcome: outcome)
			return outcome
		}

		private mutating func readSnapshot() async {
			guard
				let athlete = raw.profile?.objectFields["id"]?.stringValue.flatMap(
					IntervalsAthleteID.init(rawValue:))
			else {
				failures.append("snapshot: not read, because the profile read gave no athlete id")
				return
			}
			let clock = SystemClock()
			let diagnostics = DiagnosticsLog(clock: clock)
			let reader = TrainingSnapshotReader(
				clock: clock, deadlineSleep: clock.sleep, diagnostics: diagnostics)
			let training = TrainingConnection.connected(
				ConnectedTraining(connection: ConnectionID(), athlete: athlete, client: client))
			do {
				let read = try await reader.snapshot(
					for: training, attempt: AttemptID(ulid: ULID.generate(at: clock.now)))
				snapshot = PromptAssembly.snapshotSection(read)
				if case .unavailable = read {
					let causes = diagnostics.entries.map { String(describing: $0.event) }
					let cause = causes.isEmpty ? "nothing usable" : causes.joined(separator: ", ")
					failures.append("snapshot: the coach is given no lines (\(cause))")
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

		mutating func read(
			_ name: String, audit: (JSONValue, JSONValue) -> [String],
			_ read: () async throws -> JSONValue
		) async -> LiveReadOutcome {
			let given: JSONValue
			do {
				given = try await read()
			} catch let error as IntervalsError {
				return threw(name, "\(error.code): \(error.details)")
			} catch {
				return threw(name, String(describing: error))
			}
			let responses = LiveResponseTap.drain()
			save(responses, as: name)
			record { [folder] in try folder.write(json: given, to: "given/\(name).json") }
			let outcome = LiveReadOutcome(responses: responses, given: given)
			guard let response = outcome.answer else {
				failures.append("\(name): no raw response was captured")
				return outcome
			}
			switch response.parsed {
			case .success(let json):
				failures += audit(json, given)
			case .failure(let error):
				failures.append("\(name): the raw response is not JSON (\(error))")
			}
			return outcome
		}

		private mutating func threw(_ name: String, _ reason: String) -> LiveReadOutcome {
			let responses = LiveResponseTap.drain()
			save(responses, as: name)
			failures.append(
				(["\(name): the read threw \(reason)"]
					+ responses.map {
						"intervals.icu answered HTTP \($0.status) to \($0.request): \($0.excerpt)"
					})
					.joined(separator: "; "))
			return LiveReadOutcome(responses: responses, given: nil)
		}

		mutating func save(_ responses: [TappedResponse], as name: String) {
			for (position, response) in responses.enumerated() {
				let file =
					"raw/\(index.count)-\(name)\(responses.count > 1 ? "-\(position + 1)" : "").json"
				record { [folder] in try folder.write(try response.redactedBody(), to: file) }
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
	}
#endif
