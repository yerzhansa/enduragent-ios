#if DEBUG
	public enum FormattedReplyFixture {
		public static var source: String {
			let introduction = """
				# Next week at a glance

				Your **Fitness** is 58 and your **Form** is −9 after three hard days, so the week opens easy and builds to one threshold ride. These numbers come from intervals.icu, recorded through 17 Mar 1998.

				## The plan

				1. **Tuesday 19 Mar** — endurance, 60 min in Zone 2.
				2. **Thursday 21 Mar** — threshold, 3 × 10 min at 232–245 W with 5 min easy between.
				3. **Saturday 23 Mar** — long ride, 2 h 30 min, mostly Zone 2 with the climbs in Zone 3.

				| Day | Workout | Time | Load |
				|---|---|---:|---:|
				| Tue | Endurance | 60 min | 48 |
				| Thu | Threshold 3 × 10 | 70 min | 82 |
				| Sat | Long ride | 150 min | 131 |

				That is 280 min and a weekly Load of 261, close to your last four weeks.

				## Why these watts

				- Your FTP in intervals.icu is **258 W**, set on 2 Mar 1998.
				- Threshold work sits at 90–95% of FTP, which is *232–245 W* for you.
				- ~~Sweet spot on Wednesday~~ moved to Thursday, because Wednesday is your commute day.
				- If the first interval feels harder than a 7 out of 10, hold 232 W for the other two.

				## The last eight weeks

				| Week | Rides | Time | Load |
				|---|---|---:|---:|
				| 21 Jan | 4 | 5h 10m | 244 |
				| 28 Jan | 5 | 6h 05m | 287 |
				| 4 Feb | 3 | 3h 40m | 171 |
				| 11 Feb | 4 | 5h 25m | 256 |
				| 18 Feb | 5 | 6h 20m | 301 |
				| 25 Feb | 4 | 4h 55m | 238 |
				| 4 Mar | 5 | 6h 10m | 292 |
				| 11 Mar | 4 | 5h 35m | 268 |

				The week of 4 Feb was light because you logged a cold on the 5th. Nothing else in these weeks changes the plan.

				## Your last three threshold rides

				| Date | Intervals | Average | Felt |
				|---|---|---|---|
				| 12 Feb | 3 × 8 min | 236 W | 6 of 10 |
				| 26 Feb | 3 × 10 min | 238 W | 7 of 10 |
				| 7 Mar | 2 × 12 min | 241 W | 8 of 10 |

				Each ride held the target, and the one on 7 Mar felt hardest because it came after two days of commuting. Thursday repeats the 26 Feb session rather than stretching the intervals again. When 3 × 10 min at 238 W feels like a 6, the next step is 3 × 12 min.

				## Saturday's food and water

				- Eat a normal breakfast about two hours before you start: porridge, a banana, and coffee if you usually have it.
				- Aim for one bottle an hour; two bottles and a refill stop cover 2 h 30 min in March weather.
				- Take something every 40 min from the first hour: a bar, a gel, or a rice cake, whichever you already use.
				- If the forecast is below 5 °C, add a thermal layer rather than skipping the ride; the plan does not depend on speed.

				## If the week goes wrong

				1. **Sick or run down:** skip Thursday, ride Saturday easy for 90 min, and tell me how you feel on Monday.
				2. **Missed Tuesday:** do not move it; Thursday still works on its own.
				3. **Missed Thursday:** move it to Friday only if Saturday becomes an easy 2 h ride.
				4. **Great legs on Saturday:** stay in Zone 2 anyway; next week has the room to build.

				## On a head unit

				If you ride Thursday from a head unit, the steps read like this:

				```
				Warm-up    15 min   Zone 1 → 2
				3 ×        10 min   232–245 W
				            5 min   Zone 1
				Cool-down  10 min   Zone 1
				```

				Keep cadence where it feels natural; the target is `232–245 W`, not a cadence number.

				## What to watch

				- If your resting heart rate is 5 bpm or more above your usual 48 bpm on Thursday morning, swap Thursday and Saturday.
				- If Saturday is wet, 90 min on the trainer in Zone 2 keeps most of the Load.
				- Eat before the long ride; last time you rode 2 h 30 min fasted, the final hour faded.

				## What I will look at next Monday

				- Whether Thursday's three intervals averaged inside 232–245 W, and how the last one felt.
				- Your resting heart rate on Friday and Sunday mornings, compared with your usual 48 bpm.
				- Saturday's time in Zone 2 against the planned 150 min, not the average speed.
				- How your Form moves from −9: a small rise by Monday means the week was about right.

				If those four look fine, the following week adds 10 min to Saturday and keeps Thursday the same.

				## Links

				- Background reading: [threshold basics](https://www.example.com/threshold-basics).
				- Bike fit booking: [call the shop](tel:+15550100).
				- Calendar deep link: [open in the calendar app](intervals-calendar://week/1998-03-18).
				- A line that looks like markup stays text: <b>not bold</b> and <script>nothing runs</script>.

				Tell me if Thursday needs to move and I will rebuild the week around it.

				[Training calendar](http://example.com/calendar)

				- Outer item
				  1. Nested item with `238 W`
				  2. Another nested item

				First line
				Second line

				> **Literal quote**

				---

				<div>
				**Literal HTML**
				</div>
				"""
			return introduction + "\n\n```text\n" + String(repeating: "238 W Zone 2\n", count: 800)
				+ "```\n\nEND FORMATTED REPLY"
		}

		public static var streamingPrefix: String { String(source.prefix(source.count / 2)) }

		public static var finished: ScriptedReply {
			ScriptedReply([.text(source), .finish(reason: .stop)])
		}

		public static var streamingThenHang: ScriptedReply {
			let prefix = streamingPrefix
			var events: [ScriptedEvent] = []
			var start = prefix.startIndex
			while start < prefix.endIndex {
				let end =
					prefix.index(start, offsetBy: 128, limitedBy: prefix.endIndex)
					?? prefix.endIndex
				events.append(.text(String(prefix[start..<end])))
				start = end
			}
			events.append(.hang)
			return ScriptedReply(events, deltaDelay: .milliseconds(50))
		}
	}
#endif
