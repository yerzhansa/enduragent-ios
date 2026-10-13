#if DEBUG
	public enum NumbersReplyFixture {
		public static var source: String { held + "\n" + laterLaps + "\n\n" + closing }

		public static let held = """
			Here are the numbers for the Saturday ride.

			## Summary

			| Metric | Value |
			|---|---:|
			| Start | 1998-03-14 07:42 |
			| Sport | Ride |
			| Distance | 42.5 km |
			| Moving time | 1 h 28 min |
			| Elapsed time | 1 h 34 min |
			| Elevation gain | 312 m |
			| Average speed | 29.0 km/h |
			| Average power | 187 W |
			| Normalized power | 201 W |
			| Intensity | 78 % |
			| Load | 89 |
			| Average heart rate | 142 bpm |
			| Maximum heart rate | 171 bpm |
			| Average cadence | 86 rpm |
			| Decoupling | −1.4 % |
			| Calories | unavailable |

			## Laps

			| Lap | Elapsed time | Distance | Normalized power | Average heart rate |
			|---|---:|---:|---:|---:|
			| Warm-up | 15 min 02 s | 6.84 km | 148 W | 118 bpm |
			| Interval 1 | 10 min 00 s | 5.21 km | 240 W | 158 bpm |
			| Recovery 1 | 5 min 04 s | 2.02 km | 121 W | 131 bpm |
			"""

		public static let laterLaps = """
			| Interval 2 | 10 min 00 s | 5.18 km | | 161 bpm |
			| Recovery 2 | 5 min 01 s | 1.98 km | 118 W | 133 bpm |
			| Interval 3 | 10 min 00 s | 5.09 km | 238 W | 164 bpm |
			| Recovery 3 | 4 min 58 s | | 116 W | 136 bpm |
			| Tempo | 12 min 30 s | 6.31 km | 205 W | 151 bpm |
			| Cool-down | 15 min 27 s | 7.87 km | 132 W | 122 bpm |
			"""

		public static let closing = "END NUMBERS REPLY"

		public static var finished: ScriptedReply {
			ScriptedReply([.text(source), .finish(reason: .stop)])
		}

		public static var heldThenHang: ScriptedReply { .deltasThenHang(held) }
	}
#endif
