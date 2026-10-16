@testable import EnduragentCoach

extension CalendarWriterTests {
	static let tempoRide: [String: JSONValue] = [
		"id": .number(301), "start_date_local": .string("1998-06-16T00:00:00"),
		"category": .string("WORKOUT"), "type": .string("Ride"), "name": .string("Tempo ride"),
		"description": .string("Warmup\n- 10m 60%\nMain set\n- 3x10m 85%"),
		"moving_time": .number(3000), "icu_training_load": .number(55),
		"external_id": .string("cycling-coach:E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
		"uid": .string("server-owned"), "tags": .array([.string(IntervalsPolicy.coachTag)]),
	]
	static let endurance: [String: JSONValue] = [
		"id": .number(101), "start_date_local": .string("1998-06-17T00:00:00"),
		"category": .string("WORKOUT"), "type": .string("Ride"), "name": .string("Endurance"),
		"description": .string("Steady ride"), "moving_time": .number(4500),
		"icu_training_load": .number(50), "external_id": .string("cycling-coach:endurance"),
		"tags": .array([.string(IntervalsPolicy.coachTag)]),
	]
	static let sweetSpot: [String: JSONValue] = [
		"id": .number(104), "start_date_local": .string("1998-06-24T00:00:00"),
		"category": .string("WORKOUT"), "type": .string("Ride"), "name": .string("Sweet spot"),
		"description": .string("Warmup\n- 10m 60%\nMain set\n- 3x15m 90%"),
		"moving_time": .number(3600), "icu_training_load": .number(61),
		"workout_doc": .object([
			"duration": .number(3300),
			"steps": .array([
				.object(["duration": .number(600)]),
				.object(["reps": .number(3), "duration": .number(900)]),
			]),
		]),
		"external_id": .string("cycling-coach:sweet-spot"),
		"tags": .array([.string(IntervalsPolicy.coachTag)]),
	]
	static let recoverySpin: [String: JSONValue] = [
		"id": .number(112), "start_date_local": .string("1998-07-07T00:00:00"),
		"category": .string("WORKOUT"), "type": .string("Ride"), "name": .string("Recovery spin"),
		"moving_time": .number(3600), "icu_training_load": .number(40),
		"tags": .array([.string(IntervalsPolicy.coachTag)]),
	]
}
