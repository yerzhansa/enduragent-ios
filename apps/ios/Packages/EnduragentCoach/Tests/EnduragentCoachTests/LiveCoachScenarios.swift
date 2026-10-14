import Foundation

@testable import EnduragentCoach

enum LiveSetting: String, Sendable {
	case connected
	case notConnected = "not connected"
	case readsFailing = "both snapshot reads failing"
	case implausibleFTP = "FTP of 720 W"
}

enum LiveExpectation: Sendable, Equatable {
	case calls(ToolName)
	case neverCalls(ToolName)
	case callsWith(ToolName, argument: String, oneOf: [JSONValue])
	case neverCallsWith(ToolName, argument: String, oneOf: [JSONValue])
	case listsActivitiesCovering(CivilDate, today: CivilDate)
	case offersNoTrainingTools
	case promptHolds(String)
	case replyMentions([String])
}

struct LiveTurnPlan: Sendable {
	let message: String
	let expectations: [LiveExpectation]
}

struct LiveScenario: Sendable {
	let name: String
	let setting: LiveSetting
	let turns: [LiveTurnPlan]
}

struct LiveTurnRecord: Sendable {
	let message: String
	let exchanges: [LiveExchange]
	let reply: String?
	let outcome: String
	let reviewPending: Bool
	let calendarWrites: Int

	var chat: [LiveExchange] {
		exchanges.filter { [.chatAttempt, .stepRecovery].contains($0.request.charge) }
	}

	var toolCalls: [WireToolCall] {
		chat.flatMap { exchange in
			exchange.events.compactMap { event -> WireToolCall? in
				guard case .toolCall(let call) = event else { return nil }
				return call
			}
		}
	}

	var offeredTools: Set<String> {
		Set(chat.flatMap { $0.request.tools.map(\.name.rawValue) })
	}

	var systemPrompt: String {
		chat.first?.request.messages.first { $0.role == .system }?.content ?? ""
	}

	var athleteMessage: String? {
		chat.first?.request.messages.last { $0.role == .user }?.content
			.components(separatedBy: "\nCurrent time:").first
	}
}

enum LiveVerdict {
	static func violations(of turn: LiveTurnRecord, against expectations: [LiveExpectation])
		-> [String]
	{
		var found: [String] = []
		guard let reply = turn.reply else { return ["the turn ended \(turn.outcome)"] }
		if turn.athleteMessage != turn.message {
			found.append("the coach did not receive the athlete's message unchanged")
		}
		if reply.range(of: #"\bUTC\b"#, options: .regularExpression) != nil {
			found.append("the reply labels a time UTC")
		}
		let gated = turn.toolCalls.filter { GatedToolName(rawValue: $0.name) != nil }
		if !gated.isEmpty {
			found.append("calendar tools were called: \(gated.map(\.name).joined(separator: ", "))")
		}
		if turn.reviewPending { found.append("a workout review is waiting") }
		if turn.calendarWrites > 0 { found.append("the calendar was written") }
		let calls = turn.toolCalls.map(ParsedCall.init)
		for call in calls where call.arguments == nil {
			found.append("\(call.name) was called with arguments that are not JSON")
		}
		return found + expectations.compactMap { check($0, on: turn, calls: calls, reply: reply) }
	}

	private struct ParsedCall {
		let name: String
		let parsed: Result<[String: JSONValue], any Error>

		init(_ call: WireToolCall) {
			name = call.name
			parsed = Result { try call.parseArguments().objectFields }
		}

		var arguments: [String: JSONValue]? {
			guard case .success(let fields) = parsed else { return nil }
			return fields
		}
	}

	private static func shown(_ values: [JSONValue]) -> String {
		values.map(canonicalJSON).joined(separator: " or ")
	}

	private static func check(
		_ expectation: LiveExpectation, on turn: LiveTurnRecord, calls: [ParsedCall], reply: String
	) -> String? {
		func arguments(of tool: ToolName) -> [[String: JSONValue]] {
			calls.filter { $0.name == tool.rawValue }.map { $0.arguments ?? [:] }
		}
		switch expectation {
		case .calls(let tool):
			return arguments(of: tool).isEmpty ? "\(tool.rawValue) was not called" : nil
		case .neverCalls(let tool):
			return arguments(of: tool).isEmpty ? nil : "\(tool.rawValue) was called"
		case .callsWith(let tool, let key, let values):
			return arguments(of: tool).contains { values.contains($0[key] ?? .null) }
				? nil : "\(tool.rawValue) was not called with \(key) \(shown(values))"
		case .neverCallsWith(let tool, let key, let values):
			return arguments(of: tool).contains { values.contains($0[key] ?? .null) }
				? "\(tool.rawValue) was called with \(key) \(shown(values))" : nil
		case .listsActivitiesCovering(let date, let today):
			let covered = arguments(of: .intervalsFetchActivities).contains { fields in
				let oldest = fields["oldest"]?.stringValue.flatMap(CivilDate.init(rawValue:))
				let newest =
					fields["newest"]?.stringValue.flatMap(CivilDate.init(rawValue:)) ?? today
				return oldest.map { $0 <= date && date <= newest } ?? false
			}
			return covered ? nil : "no activity list covered \(date.rawValue)"
		case .offersNoTrainingTools:
			let offered = turn.offeredTools.filter { $0.hasPrefix("intervals_") }
			return offered.isEmpty
				? nil : "training tools were offered: \(offered.sorted().joined(separator: ", "))"
		case .promptHolds(let text):
			return turn.systemPrompt.contains(text) ? nil : "the prompt does not hold \"\(text)\""
		case .replyMentions(let words):
			let missing = words.filter { reply.range(of: $0, options: .caseInsensitive) == nil }
			return missing.isEmpty
				? nil : "the reply does not mention \(missing.joined(separator: ", "))"
		}
	}
}

struct LiveCoachPlan: Sendable {
	static let implausibleFTP = 720.0

	let scenarios: [LiveScenario]
	let unavailable: [String]

	init(listing: ActivityListing, today: CivilDate) {
		let newest = listing.activities.sorted(by: LiveReadsRun.newerFirst)
		let week = newest.filter { $0.start.date >= today.adding(days: -6) }
		var scenarios = Self.shortcuts + Self.guidance
		var unavailable: [String] = []
		if let known = week.first(where: Self.isRide) ?? week.first {
			scenarios += Self.depths(of: known)
		} else {
			unavailable.append("review depths: no activity in the last 7 days")
		}
		if let ambiguous = Self.ambiguous(in: week) {
			scenarios.append(ambiguous)
		} else {
			unavailable.append("ambiguous review: fewer than two activities of one sport in 7 days")
		}
		if let pair = Self.closePair(in: newest) {
			scenarios.append(
				LiveScenario(
					name: "review-close-pair", setting: .connected,
					turns: [
						LiveTurnPlan(
							message: "Review my activities on \(Self.day(pair.date)).",
							expectations: [
								.listsActivitiesCovering(pair.date, today: today),
								.neverCalls(.intervalsFetchStreams), .replyMentions(["infer"]),
							])
					]))
		} else {
			unavailable.append(
				"two activities close together: no pair within 30 minutes in 30 days")
		}
		self.scenarios = scenarios + Self.staged
		self.unavailable = unavailable
	}

	private static let fitnessWords = LiveExpectation.replyMentions(["Fitness", "Fatigue", "Form"])

	private static let shortcuts = [
		LiveScenario(
			name: "status", setting: .connected,
			turns: [LiveTurnPlan(message: "/status", expectations: [fitnessWords])]),
		LiveScenario(
			name: "status-with-text", setting: .connected,
			turns: [
				LiveTurnPlan(
					message: "/status how is my Form this week", expectations: [fitnessWords])
			]),
		LiveScenario(
			name: "workout-45-minutes-indoors", setting: .connected,
			turns: [LiveTurnPlan(message: "/workout 45 minutes indoors", expectations: [])]),
	]

	private static let guidance = [
		LiveScenario(
			name: "changed-goal", setting: .connected,
			turns: [
				LiveTurnPlan(
					message: "What should my main focus in training be this week?", expectations: []
				),
				LiveTurnPlan(
					message:
						"My goal has changed: I now want to ride a 160 km gran fondo in ten weeks, and I can train six hours a week. With that, what should my main focus in training be this week?",
					expectations: []),
			]),
		LiveScenario(
			name: "zones-from-ftp", setting: .connected,
			turns: [
				LiveTurnPlan(
					message:
						"What are my power zones for an FTP of 250 W? How does Sweet Spot relate to the numbered zones?",
					expectations: [
						.callsWith(
							.calculateZones, argument: "ftpWatts",
							oneOf: [.number(250), .string("250")]),
						.replyMentions(["Sweet Spot"]),
					])
			]),
		LiveScenario(
			name: "designed-workout", setting: .connected,
			turns: [
				LiveTurnPlan(
					message: "Design me a 45-minute threshold workout I can do indoors today.",
					expectations: [.replyMentions(["warm", "cool"])])
			]),
	]

	private static let staged = [
		LiveScenario(
			name: "not-connected", setting: .notConnected,
			turns: [
				LiveTurnPlan(
					message: "/status",
					expectations: [
						.offersNoTrainingTools, .promptHolds("Training data is not connected."),
					])
			]),
		LiveScenario(
			name: "reads-failing", setting: .readsFailing,
			turns: [
				LiveTurnPlan(
					message: "What workout should I do today?",
					expectations: [.promptHolds(PromptStaticBlocks.snapshotFallback)])
			]),
		LiveScenario(
			name: "ftp-not-usable", setting: .implausibleFTP,
			turns: [
				LiveTurnPlan(
					message: "Give me a threshold workout with watt targets for today.",
					expectations: [
						.promptHolds("FTP 720 W (not usable)"),
						.promptHolds(PromptStaticBlocks.snapshotQualitativeFTP),
						.neverCallsWith(
							.calculateZones, argument: "ftpWatts",
							oneOf: [.number(implausibleFTP), .string("720")]),
					])
			]),
	]

	private static func depths(of known: Activity) -> [LiveScenario] {
		let scope = describe(known)
		let id = JSONValue.string(known.id.rawValue)
		let numbers = "show numbers"
		return [
			LiveScenario(
				name: "review-brief", setting: .connected,
				turns: [
					LiveTurnPlan(
						message: "/review brief \(scope)",
						expectations: [
							.calls(.intervalsFetchActivities), .neverCalls(.intervalsFetchActivity),
							.neverCalls(.intervalsFetchStreams),
						]),
					LiveTurnPlan(
						message: numbers,
						expectations: [
							.calls(.intervalsFetchActivity), .neverCalls(.intervalsFetchStreams),
						]),
				]),
			LiveScenario(
				name: "review-default", setting: .connected,
				turns: [
					LiveTurnPlan(
						message: "/review \(scope)",
						expectations: [
							.callsWith(
								.intervalsFetchActivity, argument: "activityId", oneOf: [id]),
							.neverCalls(.intervalsFetchStreams),
						]),
					LiveTurnPlan(
						message: numbers, expectations: [.neverCalls(.intervalsFetchStreams)]),
				]),
			LiveScenario(
				name: "review-deep", setting: .connected,
				turns: [
					LiveTurnPlan(
						message: "/review deep \(scope)",
						expectations: [
							.callsWith(
								.intervalsFetchActivity, argument: "activityId", oneOf: [id]),
							.callsWith(.intervalsFetchStreams, argument: "activityId", oneOf: [id]),
						]),
					LiveTurnPlan(message: numbers, expectations: []),
				]),
		]
	}

	private static func ambiguous(in week: [Activity]) -> LiveScenario? {
		let bySport = Dictionary(grouping: week) { sportWord($0) }
		guard let pick = bySport.filter({ $0.value.count >= 2 }).min(by: { $0.key < $1.key }) else {
			return nil
		}
		let word = pick.key
		let chosen = pick.value[1]
		return LiveScenario(
			name: "review-ambiguous", setting: .connected,
			turns: [
				LiveTurnPlan(
					message: "/review my \(word) this week",
					expectations: [
						.neverCalls(.intervalsFetchActivity), .neverCalls(.intervalsFetchStreams),
					]),
				LiveTurnPlan(
					message: "The \(describe(chosen)).",
					expectations: [
						.callsWith(
							.intervalsFetchActivity, argument: "activityId",
							oneOf: [.string(chosen.id.rawValue)])
					]),
			])
	}

	static func closePair(in activities: [Activity]) -> LocalStart? {
		let timed = activities.filter { $0.start.secondOfDay != nil }
			.sorted(by: LiveReadsRun.newerFirst)
		for (later, earlier) in zip(timed, timed.dropFirst())
		where later.start.date == earlier.start.date {
			if let end = later.start.secondOfDay, let start = earlier.start.secondOfDay,
				end - start <= 30 * 60
			{
				return earlier.start
			}
		}
		return nil
	}

	static func describe(_ activity: Activity) -> String {
		let title = activity.name.map { "\"\($0)\"" } ?? sportWord(activity)
		let time = activity.start.secondOfDay.map {
			String(format: " at %02d:%02d", $0 / 3_600, $0 / 60 % 60)
		}
		return "\(title) on \(day(activity.start.date))\(time ?? "")"
	}

	static func day(_ date: CivilDate) -> String {
		let parts = date.rawValue.split(separator: "-").compactMap { Int($0) }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone.current
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone.current
		formatter.dateFormat = "EEEE d MMMM"
		guard parts.count == 3,
			let noon = calendar.date(
				from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
		else { return date.rawValue }
		return formatter.string(from: noon)
	}

	private static func isRide(_ activity: Activity) -> Bool {
		activity.sport.map(IntervalsPolicy.cyclingSports.contains) ?? false
	}

	private static func sportWord(_ activity: Activity) -> String {
		if isRide(activity) { return "ride" }
		return activity.sport.map { $0.lowercased() } ?? "session"
	}
}
