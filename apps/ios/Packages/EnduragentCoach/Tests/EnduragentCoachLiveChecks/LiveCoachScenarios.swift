import Foundation

@testable import EnduragentCoach

enum LiveSetting: String, Sendable {
	case connected
	case notConnected = "not connected"
	case readsFailing = "both snapshot reads failing"
	case implausibleFTP = "FTP of 720 W"
	case reviewing = "connected, preparing workout reviews"
	case approving = "connected, approving workout reviews on the seeded account"

	private static let preparesNothing: [LiveExpectation] = [
		.review(.preparesNothing), .review(.leavesNoReview),
	]

	var standing: [LiveExpectation] {
		let connected: [LiveExpectation] = [
			.promptHolds(PromptStaticBlocks.snapshotHeading),
			.promptLacks(PromptStaticBlocks.snapshotFallback),
		]
		switch self {
		case .connected: return connected + Self.preparesNothing
		case .reviewing, .approving: return connected
		case .notConnected, .readsFailing, .implausibleFTP: return Self.preparesNothing
		}
	}
}

enum LiveExpectation: Sendable, Equatable {
	case calls(ToolName)
	case neverCalls(ToolName)
	case callsWith(ToolName, argument: String, oneOf: [JSONValue])
	case neverCallsWith(ToolName, argument: String, oneOf: [JSONValue])
	case listsActivitiesCovering(CivilDate, today: CivilDate)
	case offersNoTrainingTools
	case promptHolds(String)
	case promptLacks(String)
	case replyMentions([String])
	case review(LiveReviewExpectation)
	case plan(LivePlanExpectation)
}

struct LiveTurnPlan: Sendable {
	let message: String
	let expectations: [LiveExpectation]
	var tapsSavePlan = false
	var approvesReview = false
}

struct LiveScenario: Sendable {
	let name: String
	let setting: LiveSetting
	let turns: [LiveTurnPlan]
	let targets: [LiveSeededTarget]
	let endsWithCancel: Bool

	init(
		name: String, setting: LiveSetting, turns: [LiveTurnPlan],
		targets: [LiveSeededTarget] = [], endsWithCancel: Bool = false
	) {
		self.name = name
		self.setting = setting
		self.targets = targets
		self.endsWithCancel = endsWithCancel
		self.turns = turns.map {
			LiveTurnPlan(
				message: $0.message, expectations: setting.standing + $0.expectations,
				tapsSavePlan: $0.tapsSavePlan, approvesReview: $0.approvesReview)
		}
	}
}

struct LiveCoachPlan: Sendable {
	static let implausibleFTP = 720.0
	static let noAmbiguousDay =
		"ambiguous review: no day in the last 7 days has two activities of one sport that start more than 30 minutes apart, with no activity in between linking them"

	let scenarios: [LiveScenario]
	let unavailable: [String]

	init(listing: ActivityListing, calendar: [CalendarEvent], today: CivilDate) {
		let newest = listing.activities.sorted { $0.start > $1.start }
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
			unavailable.append(Self.noAmbiguousDay)
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
		switch Self.reviews(on: calendar, today: today) {
		case .success(let reviews): scenarios += reviews
		case .failure(let missing): unavailable.append(missing.description)
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
		let days = Dictionary(grouping: week.filter { $0.start.secondOfDay != nil }) {
			$0.start.date
		}
		let candidates = days.flatMap { date, activities in
			let workouts = inferredWorkouts(activities)
			return Set(activities.map(sportWord)).compactMap {
				word -> (word: String, date: CivilDate, chosen: Activity)? in
				let holding = workouts.filter { $0.contains { sportWord($0) == word } }
				guard holding.count >= 2,
					let chosen = holding.last?.last(where: { sportWord($0) == word })
				else { return nil }
				return (word, date, chosen)
			}
		}
		guard let pick = candidates.min(by: { ($0.word, $1.date) < ($1.word, $0.date) }) else {
			return nil
		}
		let chosen = pick.chosen
		return LiveScenario(
			name: "review-ambiguous", setting: .connected,
			turns: [
				LiveTurnPlan(
					message: "/review my \(pick.word) on \(day(pick.date))",
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

	private static func inferredWorkouts(_ activities: [Activity]) -> [[Activity]] {
		let timed = activities.compactMap { activity in
			activity.start.secondOfDay.map { (activity, $0) }
		}.sorted { $0.1 < $1.1 }
		var workouts: [[(Activity, Int)]] = []
		for entry in timed {
			if let previous = workouts.last?.last, entry.1 - previous.1 <= 30 * 60 {
				workouts[workouts.count - 1].append(entry)
			} else {
				workouts.append([entry])
			}
		}
		return workouts.map { $0.map(\.0) }
	}

	static func closePair(in activities: [Activity]) -> LocalStart? {
		let timed = activities.filter { $0.start.secondOfDay != nil }
			.sorted { $0.start > $1.start }
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
