import Darwin
import Foundation

package struct DiagnosticsFile: Sendable, Encodable {
	package static let format = 1

	private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

	package let made: Date
	package let app: AppIdentity
	package let device: DeviceFacts
	package let access: AccessKind
	package let training: ConnectionKind
	package let language: LanguageCode
	package let records: RecordCensus
	package let journal: JournalHealth
	package let lines: [StampedLine]

	private enum Key: String, CodingKey {
		case format
		case made
		case app
		case device
		case access
		case training
		case language
		case records
		case journal
		case lines
	}

	package init(
		made: Date, app: AppIdentity, device: DeviceFacts, facts: StatusFacts,
		records: RecordCensus, journal: JournalHealth, lines: [StampedLine]
	) {
		self.made = made
		self.app = app
		self.device = device
		access = facts.access
		training = facts.training
		language = facts.language
		self.records = records
		self.journal = journal
		self.lines = lines
	}

	package func encoded() throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		encoder.dateEncodingStrategy = .custom { date, encoder in
			var container = encoder.singleValueContainer()
			try container.encode(date.formatted(Self.stamp))
		}
		return try encoder.encode(self)
	}

	package func name(in timeZone: TimeZone) -> String {
		let style = Date.VerbatimFormatStyle(
			format:
				"\(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
			timeZone: timeZone, calendar: Calendar(identifier: .gregorian))
		return "enduragent-diagnostics-\(made.formatted(style)).json"
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		try container.encode(Self.format, forKey: .format)
		try container.encode(made, forKey: .made)
		try container.encode(app, forKey: .app)
		try container.encode(device, forKey: .device)
		try container.encode(access, forKey: .access)
		try container.encode(training, forKey: .training)
		try container.encode(language, forKey: .language)
		try container.encode(records, forKey: .records)
		try container.encode(journal, forKey: .journal)
		try container.encode(lines, forKey: .lines)
	}
}

package struct AppIdentity: Sendable, Equatable, Encodable {
	package let name: String
	package let version: String
	package let build: String

	package init?(name: String, version: String, build: String) {
		guard fits(name, #/[A-Za-z][A-Za-z ]{0,29}/#),
			fits(version, #/[0-9]+(?:\.[0-9]+){0,2}/#),
			fits(build, #/[0-9]+(?:\.[0-9]+)*/#)
		else { return nil }
		self.name = name
		self.version = version
		self.build = build
	}

	package var display: String { "\(version) (\(build))" }
}

package struct DeviceFacts: Sendable, Equatable, Encodable {
	package static let fixture = DeviceFacts(
		model: PhoneModel(parsing: "iPhone17,1"), system: SystemVersion(parsing: "26.0"))

	private static let unknown = "unknown"

	package let model: PhoneModel?
	package let system: SystemVersion?

	private enum Key: String, CodingKey {
		case model
		case system
	}

	package static func current() -> DeviceFacts {
		let system = SystemVersion(ProcessInfo.processInfo.operatingSystemVersion)
		var names = utsname()
		guard uname(&names) == 0 else { return DeviceFacts(model: nil, system: system) }
		let machine = withUnsafeBytes(of: names.machine) { bytes in
			String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
		}
		return DeviceFacts(model: PhoneModel(parsing: machine), system: system)
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		try container.encode(model?.rawValue ?? Self.unknown, forKey: .model)
		try container.encode(system?.text ?? Self.unknown, forKey: .system)
	}
}

package struct PhoneModel: Sendable, Equatable {
	private static let simulatorMachines: Set<String> = ["arm64", "x86_64"]

	package let rawValue: String

	package init?(parsing machine: String) {
		if Self.simulatorMachines.contains(machine) {
			rawValue = "simulator"
			return
		}
		guard fits(machine, #/[A-Za-z]{1,16}[0-9]{1,4},[0-9]{1,4}/#) else { return nil }
		rawValue = machine
	}
}

package struct SystemVersion: Sendable, Equatable {
	package let major: Int
	package let minor: Int
	package let patch: Int

	package init(_ version: OperatingSystemVersion) {
		major = version.majorVersion
		minor = version.minorVersion
		patch = version.patchVersion
	}

	package init?(parsing text: String) {
		let shape = #/([0-9]{1,4})\.([0-9]{1,4})(?:\.([0-9]{1,4}))?/#
			.matchingSemantics(.unicodeScalar)
		guard let match = text.wholeMatch(of: shape),
			let major = Int(match.1), let minor = Int(match.2)
		else { return nil }
		self.major = major
		self.minor = minor
		patch = match.3.flatMap { Int($0) } ?? 0
	}

	var text: String { "\(major).\(minor).\(patch)" }
}

package enum AccessKind: Sendable, Equatable, Encodable {
	case none
	case credits(Availability)
	case openRouterAccount(Availability)

	package enum Availability: String, Sendable, Encodable {
		case ready
		case needsSetup
		case unavailable

		init(_ availability: AccessAvailability) {
			switch availability {
			case .ready: self = .ready
			case .needsSetup: self = .needsSetup
			case .unavailable: self = .unavailable
			}
		}
	}

	private enum Key: String, CodingKey {
		case method
		case availability
	}

	package init(_ status: AccessStatus) {
		let availability = Availability(status.availability)
		switch status.selection?.method ?? status.savedMethod {
		case nil: self = .none
		case .credits: self = .credits(availability)
		case .openRouterAccount: self = .openRouterAccount(availability)
		}
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		switch self {
		case .none:
			try container.encode("none", forKey: .method)
		case .credits(let availability):
			try container.encode(AccessMethod.credits, forKey: .method)
			try container.encode(availability, forKey: .availability)
		case .openRouterAccount(let availability):
			try container.encode(AccessMethod.openRouterAccount, forKey: .method)
			try container.encode(availability, forKey: .availability)
		}
	}
}

package enum ConnectionKind: String, Sendable, Equatable, Encodable {
	case unconnected
	case connected
	case unavailable

	package init(_ status: TrainingStatus) {
		switch status {
		case .unconnected: self = .unconnected
		case .connected: self = .connected
		case .unavailable: self = .unavailable
		}
	}
}

package struct LanguageCode: Sendable, Equatable, Encodable {
	package let rawValue: String

	package init(_ preference: LanguagePreference) {
		rawValue = preference.id
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(rawValue)
	}
}

package struct StatusFacts: Sendable, Equatable {
	package let access: AccessKind
	package let training: ConnectionKind
	package let language: LanguageCode
}

package enum RecordCensus: Sendable, Equatable, Encodable {
	case counted(synced: [SyncedKind: Int], local: [DeviceLocalKind: Int], skipped: Int)
	case unavailable(LedgerFailure)

	private enum Key: String, CodingKey {
		case synced
		case local
		case skipped
		case unavailable
	}

	package func encode(to encoder: any Encoder) throws {
		var container = encoder.container(keyedBy: Key.self)
		switch self {
		case .counted(let synced, let local, let skipped):
			try container.encode(Self.counts(synced), forKey: .synced)
			try container.encode(Self.counts(local), forKey: .local)
			try container.encode(skipped, forKey: .skipped)
		case .unavailable(let failure):
			try container.encode(FailureCode.ledger(failure).code, forKey: .unavailable)
		}
	}

	private static func counts<Kind>(_ counted: [Kind: Int]) -> [String: Int]
	where Kind: RawRepresentable & CaseIterable & Hashable, Kind.RawValue == String {
		Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0.rawValue, counted[$0] ?? 0) })
	}
}

private func fits(_ text: String, _ shape: Regex<Substring>) -> Bool {
	text.wholeMatch(of: shape.matchingSemantics(.unicodeScalar)) != nil
}

package struct SupportCensus: Sendable {
	package let status: @Sendable () async -> StatusFacts
	package let records: @Sendable () async -> RecordCensus
}
