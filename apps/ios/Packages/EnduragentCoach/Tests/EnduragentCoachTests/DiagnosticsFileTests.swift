import EnduragentCoachFixtures
import Foundation
import Testing

@testable import EnduragentCoach

@Suite struct DiagnosticsFileTests {
	static let made = Date(timeIntervalSince1970: 1_793_092_443.5)

	static func file(
		access: AccessStatus = AccessStatus(state: .credits(.ready), builtInModel: testModel),
		training: TrainingStatus = .unconnected,
		language: LanguagePreference = .fixed(.fr),
		device: DeviceFacts = .fixture,
		records: RecordCensus = .counted(
			synced: [.userMessage: 4, .dailyNote: 1], local: [.turnClaim: 2], legacy: [:],
			skipped: 3),
		journal: JournalHealth = .saving,
		lines: [StampedLine] = []
	) throws -> DiagnosticsFile {
		let app = try #require(AppIdentity(name: "Enduragent", version: "0.1.0", build: "3"))
		return DiagnosticsFile(
			made: made, app: app, device: device,
			facts: StatusFacts(
				access: AccessKind(access), training: ConnectionKind(training),
				language: LanguageCode(language)),
			records: records, journal: journal, lines: lines)
	}

	static func fields(_ file: DiagnosticsFile) throws -> [String: JSONValue] {
		try JSONValue.parse(String(decoding: file.encoded(), as: UTF8.self)).objectFields
	}

	@Test func aFileEncodesItsTenSectionsWithFormatOne() throws {
		let fields = try Self.fields(Self.file())
		#expect(
			Set(fields.keys) == [
				"format", "made", "app", "device", "access", "training", "language", "records",
				"journal", "lines",
			])
		#expect(fields["format"] == .number(1))
		#expect(fields["made"] == .string("2026-10-27T09:14:03.500Z"))
		#expect(
			fields["app"]
				== .object([
					"name": .string("Enduragent"), "version": .string("0.1.0"),
					"build": .string("3"),
				]))
		#expect(
			fields["device"]
				== .object(["model": .string("iPhone17,1"), "system": .string("26.0.0")]))
		#expect(
			fields["access"]
				== .object(["method": .string("credits"), "availability": .string("ready")]))
		#expect(fields["training"] == .string("unconnected"))
		#expect(fields["language"] == .string("fr"))
		let records = fields["records"]?.objectFields ?? [:]
		#expect(records["synced"]?.objectFields["userMessage"] == .number(4))
		#expect(records["synced"]?.objectFields["dailyNote"] == .number(1))
		#expect(records["synced"]?.objectFields.count == SyncedKind.allCases.count)
		#expect(records["local"]?.objectFields["turnClaim"] == .number(2))
		#expect(records["local"]?.objectFields["providerConsent"] == .number(0))
		#expect(records["skipped"] == .number(3))
		#expect(fields["journal"] == .object(["saving": .object([:])]))
		#expect(fields["lines"] == .array([]))
	}

	@Test func aFileStatesAnUnreadableStoreAndALogThatIsNotSaving() throws {
		let fields = try Self.fields(
			Self.file(
				access: AccessStatus(
					state: .unreadable(.secureStorageLocked), builtInModel: testModel),
				training: .unavailable(.secureStorageLocked), language: .automatic,
				records: .unavailable(.unavailable),
				journal: .notSaving(since: Self.made, firstCause: .appendFailed)))
		#expect(fields["access"] == .object(["method": .string("none")]))
		#expect(fields["training"] == .string("unavailable"))
		#expect(fields["language"] == .string("automatic"))
		#expect(fields["records"] == .object(["unavailable": .string("ledger.unavailable")]))
		#expect(
			fields["journal"]
				== .object([
					"notSaving": .object([
						"since": .string("2026-10-27T09:14:03.500Z"),
						"firstCause": .string("appendFailed"),
					])
				]))
	}

	@Test func aFileFromSeededInputsHoldsNoKeyAthleteIdMessageOrTrainingValue() throws {
		let openRouterKey = "sk-or-v1-" + String(repeating: "7f3a", count: 16)
		let athleteID = "i" + String(12_345_678)
		let intervalsKey = "intervals-test-key-7f3a"
		let sentence = "My threshold is 287 watts and the Sweet Spot Seventeen session hurt"
		let athlete = try #require(IntervalsAthleteID(rawValue: athleteID))
		let today = try #require(CivilDate(rawValue: "2026-10-26"))
		let day = WellnessDay(date: today, readings: Readings([.weight: 72.4, .fitness: 61.7]))
		let profile = IntervalsProfile(
			athleteID: athlete, name: sentence, wellness: .available(.day(day)))
		let summary = IntervalsSummary(
			connectionID: ConnectionID(), keySuffix: String(intervalsKey.suffix(4)),
			profile: .available(profile))
		let body =
			#"{"error":{"code":"x","message":"\#(sentence) with key \#(openRouterKey) for \#(athleteID) "#
			+ #"and \#(intervalsKey): FTP 287 W, weight 72.4 kg, Sweet Spot Seventeen"}}"#
		let events: [DiagnosticsEvent] = [
			.providerFailure(
				AttemptID(ulid: fixedUlid(1)), .serverError(status: 502, retryAfter: .seconds(3)),
				detail: ProviderDetail.parse(status: 502, body: body)),
			.skippedRecord(
				.newerVersion(kind: "Bearer " + intervalsKey, version: 9, ulid: openRouterKey)),
		]
		let file = try Self.file(
			training: .connected(
				summary, account: .intervals(connection: ConnectionID(), athlete: athlete)),
			lines: events.map { StampedLine(at: Self.made, line: .problem($0.line)) })
		let text = String(decoding: try file.encoded(), as: UTF8.self)
		for seeded in [
			openRouterKey, "sk-or-v1-", athleteID, intervalsKey, sentence, "Sweet Spot Seventeen",
			"287 W", "287 watts", "72.4", "61.7",
		] {
			#expect(!text.contains(seeded), "the file holds \(seeded.prefix(12))")
		}
		#expect(text.contains("providerFailure"))
		#expect(text.contains("[redacted]"))
		#expect(try Self.fields(file)["training"] == .string("connected"))
	}

	@Test func shareOutcomeMapsTheShareSheetCompletion() {
		let saveToFiles = "com.apple.DocumentManagerUICore.SaveToFiles"
		let airDrop = "com.apple.UIKit.activity.AirDrop"
		let failure = CocoaError(.fileWriteUnknown)
		#expect(ShareOutcome.of(activityType: saveToFiles, completed: true, error: nil) == .saved)
		#expect(ShareOutcome.of(activityType: airDrop, completed: true, error: nil) == .shared)
		#expect(ShareOutcome.of(activityType: nil, completed: true, error: nil) == .shared)
		#expect(
			ShareOutcome.of(activityType: saveToFiles, completed: false, error: nil) == .canceled)
		#expect(ShareOutcome.of(activityType: nil, completed: false, error: nil) == .canceled)
		#expect(
			ShareOutcome.of(activityType: saveToFiles, completed: true, error: failure) == .failed)
		#expect(ShareOutcome.of(activityType: nil, completed: false, error: failure) == .failed)
	}

	@Test(arguments: [
		"", "iPhone", "iPhone17", "17,1", "iPhone17,1 ", "iPhone17,1\u{301}", "sk-or-v1-abc",
	])
	func aBadPhoneModelIsNil(_ machine: String) {
		#expect(PhoneModel(parsing: machine) == nil)
	}

	@Test(arguments: ["", "26", "26.", "v26.0", "26.0.1.2", "26.x", "26.0 beta", "２６.0"])
	func aBadSystemVersionIsNil(_ text: String) {
		#expect(SystemVersion(parsing: text) == nil)
	}

	@Test func phoneModelsAndSystemVersionsOfTheirShapeParse() throws {
		#expect(PhoneModel(parsing: "iPhone17,1")?.rawValue == "iPhone17,1")
		#expect(PhoneModel(parsing: "arm64")?.rawValue == "simulator")
		#expect(PhoneModel(parsing: "x86_64")?.rawValue == "simulator")
		#expect(SystemVersion(parsing: "18.6.2")?.text == "18.6.2")
		#expect(SystemVersion(parsing: "26.1")?.text == "26.1.0")
	}

	@Test func aDeviceThatDidNotParseIsWrittenAsUnknown() throws {
		let device = DeviceFacts(
			model: PhoneModel(parsing: "Watch\u{0}"), system: SystemVersion(parsing: "twenty six"))
		#expect(
			try Self.fields(Self.file(device: device))["device"]
				== .object(["model": .string("unknown"), "system": .string("unknown")]))
	}

	@Test func theCurrentDeviceIsReadFromTheSystem() throws {
		let current = DeviceFacts.current()
		let running = ProcessInfo.processInfo.operatingSystemVersion
		#expect(
			current.system?.text
				== "\(running.majorVersion).\(running.minorVersion).\(running.patchVersion)")
		#expect(current.model != nil)
	}

	@Test func anAppIdentityRefusesTextOutsideItsShapes() {
		#expect(
			AppIdentity(name: "Enduragent", version: "0.1.0", build: "3")?.display == "0.1.0 (3)")
		#expect(AppIdentity(name: "Enduragent ", version: "0.1", build: "3.2.1.9") != nil)
		#expect(AppIdentity(name: "sk-or-v1-abc", version: "0.1.0", build: "3") == nil)
		#expect(AppIdentity(name: "Enduragent", version: "0.1.0.4", build: "3") == nil)
		#expect(
			AppIdentity(name: "Enduragent", version: "0.1.0", build: "i" + String(12_345_678))
				== nil)
		#expect(
			AppIdentity(name: String(repeating: "a", count: 31), version: "1", build: "1") == nil)
	}

	@Test func theFileIsNamedForItsMinuteInThePhonesTimeZone() throws {
		let file = try Self.file()
		let fiveHoursEast = try #require(TimeZone(secondsFromGMT: 5 * 3_600))
		let tenHoursWest = try #require(TimeZone(secondsFromGMT: -10 * 3_600))
		#expect(file.name(in: .gmt) == "enduragent-diagnostics-2026-10-27-0914.json")
		#expect(file.name(in: fiveHoursEast) == "enduragent-diagnostics-2026-10-27-1414.json")
		#expect(file.name(in: tenHoursWest) == "enduragent-diagnostics-2026-10-26-2314.json")
	}
}
