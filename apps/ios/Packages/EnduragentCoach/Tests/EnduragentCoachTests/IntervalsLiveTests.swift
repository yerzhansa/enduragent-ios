import Foundation
import Testing

@testable import EnduragentCoach

@Suite
struct IntervalsLiveTests {
	static var hasAPIKey: Bool {
		ProcessInfo.processInfo.environment["INTERVALS_API_KEY"].map { !$0.isEmpty } ?? false
	}

	@Test(.enabled(if: hasAPIKey))
	func repeatedChatEventUpsertsOneWriteIdentity() async throws {
		let key = try #require(ProcessInfo.processInfo.environment["INTERVALS_API_KEY"])
		let client = IntervalsRESTClient(credential: .apiKey(key))
		let today = IntervalsPolicy.today(now: Date(), timeZone: TimeZone.current)
		let date = today.adding(days: 3_650)
		let identity = CalendarWriteID()
		let name = "Enduragent upsert proof \(identity.uid)"
		let approval = ChatCalendarCreate(
			writeID: identity, date: date, name: name, description: "- 10m 60%",
			type: .ride, externalId: IntervalsSerializer.chatExternalId(date: date, name: name),
			tags: [IntervalsPolicy.coachTag])
		var created: Set<EventID> = []
		do {
			let first = try await client.createChatEvent(approval)
			created.insert(first.id)
			let second = try await client.createChatEvent(approval)
			created.insert(second.id)
			let day = try await client.listEvents(oldest: date, newest: date)
			let matches = day.filter {
				$0.uid == identity.uid || $0.externalId == identity.externalID
			}
			created.formUnion(matches.map(\.id))
			try #require(matches.count == 1)
			let saved = try #require(matches.first)
			#expect(saved.uid == identity.uid)
			#expect(saved.externalId == identity.externalID)
			#expect(approval.matches(saved))
			#expect(first.id == second.id)
		} catch {
			await removeProofEvents(client, approval: approval, known: created)
			throw error
		}
		await removeProofEvents(client, approval: approval, known: created)
	}

	private func removeProofEvents(
		_ client: IntervalsRESTClient, approval: ChatCalendarCreate, known: Set<EventID>
	) async {
		var events = known
		do {
			let day = try await client.listEvents(oldest: approval.date, newest: approval.date)
			events.formUnion(
				day.filter {
					$0.uid == approval.writeID?.uid || $0.externalId == approval.writeID?.externalID
				}.map(\.id))
		} catch {
			Issue.record(error, "Could not discover the live upsert proof events for cleanup")
		}
		for id in events.sorted(by: { $0.rawValue < $1.rawValue }) {
			do { try await client.deleteEvent(id: id) } catch {
				Issue.record(error, "Could not delete a live upsert proof event")
			}
		}
	}

	@Test(.enabled(if: hasAPIKey))
	func readsSevenDays() async throws {
		let key = try #require(ProcessInfo.processInfo.environment["INTERVALS_API_KEY"])
		let client = IntervalsRESTClient(credential: .apiKey(key))
		let today = IntervalsPolicy.today(now: Date(), timeZone: TimeZone.current)
		let days = 7
		let past = today.adding(days: -(days - 1))
		let future = today.adding(days: days - 1)

		let athlete = try await client.fetchAthlete()
		let wellness = try await client.fetchWellness(oldest: past, newest: today)
		let activities = try await client.fetchActivities(oldest: past, newest: today)
		let events = try await client.listEvents(oldest: today, newest: future)

		print(athlete.name)
		for day in wellness {
			let fitness = day.fitness.map { String($0) } ?? "none"
			let fatigue = day.fatigue.map { String($0) } ?? "none"
			let form = day.form.map { String($0) } ?? "none"
			print("\(day.date) Fitness \(fitness) Fatigue \(fatigue) Form \(form)")
		}

		var athleteJSON: [String: Any] = [
			"id": "redacted",
			"name": athlete.name,
		]
		if let ftp = athlete.ftp {
			athleteJSON["ftp"] = ftp
		}
		let payload: [String: Any] = [
			"athlete": athleteJSON,
			"wellness": wellness.map { day -> [String: Any] in
				var row: [String: Any] = ["date": day.date.rawValue]
				if let fitness = day.fitness { row["fitness"] = fitness }
				if let fatigue = day.fatigue { row["fatigue"] = fatigue }
				if let form = day.form { row["form"] = form }
				return row
			},
			"activities": activities.map { row -> [String: Any] in
				var json: [String: Any] = [
					"id": "redacted",
					"name": row.name,
					"date": row.date.rawValue,
					"durationS": row.durationS,
				]
				if let load = row.trainingLoad {
					json["trainingLoad"] = load
				}
				return json
			},
			"events": events.map { event -> [String: Any] in
				var json: [String: Any] = [
					"id": "redacted",
					"startDateLocal": event.startDateLocal,
					"name": event.name,
					"category": event.category,
					"coachCreated": event.coachCreated,
				]
				if let externalId = event.externalId {
					json["externalId"] = externalId
				}
				return json
			},
		]
		let data = try JSONSerialization.data(
			withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
		if let path = ProcessInfo.processInfo.environment["ENDURAGENT_LIVE_OUT"], !path.isEmpty {
			try data.write(to: URL(fileURLWithPath: path))
		}
	}
}
