#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation
	import Synchronization

	extension FirstWeekFixture {
		static let slowFirstWordDelay: Duration = .seconds(2)
		static let slowWordDelay: Duration = .milliseconds(250)
		static let slowFlushDelay: Duration = .seconds(6)

		static func responses(
			intervals: FakeIntervalsClient, credits: FakeCreditsClient
		) -> FakeModelTransport.Response {
			let flushes = Mutex<[String: FakeModelTransport.Response]>([:])
			return { request in
				switch request.purpose {
				case .summary:
					return ScriptedReply(summaryReply)
				case .flush:
					return flushes.withLock { scripts in
						for message in request.userMessages.reversed() {
							for (directive, respond) in scripts
							where message == directive || message.hasSuffix("] " + directive) {
								return respond(request)
							}
						}
						return ScriptedReply([.finish(reason: .stop)])
					}
				case .chat:
					if request.accessMethod == .credits, !request.retry,
						request.text == "fixture:fail 402"
					{
						install(.zero, on: credits)
					}
					if request.text == trainingDataDirective {
						return trainingDataReply(request)
					}
					if request.step == 0 {
						intervals.delayNextActivityRead(
							for: request.text == toolProgressDirective && !request.retry
								? slowToolReadDelay : .zero)
					}
					if request.text == toolProgressDirective, !request.retry {
						return toolProgressReply(step: request.step)
					}
					if request.step == 0, !request.retry {
						let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
						if text == "fixture:flush-partial" {
							flushes.withLock {
								$0[text] = PartialFlushFixture.responses()
							}
						} else if text == "fixture:slow-flush" {
							flushes.withLock {
								$0[text] = ScriptedReply.sequence(
									[.finish(reason: .stop)], for: .flush,
									requestDelay: slowFlushDelay)
							}
						}
					}
					return reply(to: request.text, retry: request.retry).step(
						request.step, repeatingHang: true)
				}
			}
		}

		private static func reply(to text: String, retry: Bool) -> ScriptedReply {
			let normal = script(for: text)
			guard !retry, text.hasPrefix("fixture:") else { return ScriptedReply(normal) }
			let words = text.dropFirst("fixture:".count).split(separator: " ").map(String.init)
			let arguments = Array(words.dropFirst())
			switch words.first {
			case "slow" where arguments.isEmpty:
				return ScriptedReply(
					weekSummaryByWord(), requestDelay: slowFirstWordDelay, deltaDelay: slowWordDelay
				)
			case "slow-flush" where arguments.isEmpty:
				return ScriptedReply(
					normal, requestDelay: slowFlushDelay)
			case "hang" where arguments.isEmpty:
				return ScriptedReply([.hang])
			case "fail":
				let repeated = repetition(arguments)
				guard let failure = failure(repeated.arguments) else { return unknown(text) }
				return ScriptedReply(
					Array(repeating: .fail(failure), count: repeated.count) + normal)
			case "memory-then-fail" where arguments.isEmpty:
				return ScriptedReply(savedMemory + [.fail(.http(status: 500))])
			case "memory-until-system-interruption" where arguments.isEmpty:
				return ScriptedReply(savedMemory + [.keepWorking])
			case "memory-then-hang" where arguments.isEmpty:
				return ScriptedReply(savedMemory + [.hang])
			case "step-limit" where arguments.isEmpty:
				return stepLimitReply(commitsMemory: false)
			case "memory-then-step-limit" where arguments.isEmpty:
				return stepLimitReply(commitsMemory: true)
			case "text-then-hang" where arguments.isEmpty:
				return ScriptedReply([.text(partialReply), .hang])
			case "teach" where arguments.isEmpty:
				return ScriptedReply(savedMemory + [.text(rememberReply), .finish(reason: .stop)])
			case "formatted" where arguments.isEmpty:
				return FormattedReplyFixture.finished
			case "formatted-then-hang" where arguments.isEmpty:
				return FormattedReplyFixture.streamingThenHang
			case "long" where arguments.isEmpty:
				return ScriptedReply([.text(longReply), .finish(reason: .stop)])
			case "flush-partial" where arguments.isEmpty:
				return ScriptedReply(normal)
			default:
				return unknown(text)
			}
		}

		static let partialReply = "This week has Tuesday sweet spot"

		private static func stepLimitReply(commitsMemory: Bool) -> ScriptedReply {
			let read: [ScriptedEvent] = [
				.toolCall(name: "intervals_fetch_activities", arguments: #"{"days":7}"#),
				.finish(reason: .toolCalls),
			]
			return ScriptedReply(
				(commitsMemory ? savedMemory : [])
					+ Array(repeating: read, count: commitsMemory ? 9 : 10).flatMap { $0 }
					+ [.finish(reason: .stop)])
		}

		static let savedMemory: [ScriptedEvent] = [
			.toolCall(
				name: ToolName.memoryWrite.rawValue,
				arguments:
					#"{"type":"memory","section":"schedule","content":"Rides with a group on Saturdays."}"#
			),
			.finish(reason: .toolCalls),
		]

		private static func repetition(_ arguments: [String]) -> (arguments: [String], count: Int) {
			guard let last = arguments.last, last.hasPrefix("x"), let count = Int(last.dropFirst()),
				count > 0
			else {
				return (arguments, 1)
			}
			return (Array(arguments.dropLast()), count)
		}

		private static func unknown(_ text: String) -> ScriptedReply {
			ScriptedReply([.text("Unknown fixture directive: \(text)"), .finish(reason: .stop)])
		}

		private static func failure(_ arguments: [String]) -> ScriptedFailure? {
			guard let code = arguments.first else { return nil }
			let rest = Array(arguments.dropFirst())
			switch code {
			case "400" where rest.isEmpty:
				return .http(status: 400)
			case "401" where rest.isEmpty:
				return .http(status: 401)
			case "402" where rest.isEmpty:
				return .http(status: 402)
			case "429" where rest.isEmpty:
				return .http(status: 429, headers: ["retry-after": "7"])
			case "429" where rest.count == 1 && Int(rest[0]) != nil:
				return .http(status: 429, headers: ["retry-after": rest[0]])
			case "500" where rest.isEmpty:
				return .http(status: 500)
			case "network" where rest.isEmpty:
				return .connection(.notConnectedToInternet)
			case "timeout" where rest.isEmpty:
				return .connection(.timedOut)
			case "overflow" where rest.isEmpty:
				return .http(
					status: 400,
					body:
						#"{"error":{"message":"This endpoint's maximum context length is 131072 tokens."}}"#
				)
			case "finish" where rest.isEmpty:
				return .unknownFinish
			default:
				return nil
			}
		}
	}
#endif
