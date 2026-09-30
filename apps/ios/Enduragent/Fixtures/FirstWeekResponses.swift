#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures
	import Foundation

	extension FirstWeekFixture {
		static let slowFirstWordDelay: Duration = .seconds(2)
		static let slowWordDelay: Duration = .milliseconds(250)
		static let slowFlushDelay: Duration = .seconds(6)

		static func respond(to request: ScriptedRequest) -> ScriptedReply {
			switch request.purpose {
			case .summary:
				return ScriptedReply(summaryReply)
			case .flush:
				let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
				return ScriptedReply(
					text == "fixture:flush-partial" && !request.retry ? flushPartial : [],
					requestDelay: text == "fixture:slow-flush" && !request.retry
						? slowFlushDelay : nil
				).step(request.step)
			case .chat:
				return reply(to: request.text, retry: request.retry).step(
					request.step, repeatingHang: true)
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
			case "memory-then-hang" where arguments.isEmpty:
				return ScriptedReply(savedMemory + [.hang])
			case "text-then-hang" where arguments.isEmpty:
				return ScriptedReply([.text(partialReply), .hang])
			case "teach" where arguments.isEmpty:
				return ScriptedReply(savedMemory + [.text(rememberReply), .finish(reason: .stop)])
			case "long" where arguments.isEmpty:
				return ScriptedReply([.text(longReply), .finish(reason: .stop)])
			case "flush-partial" where arguments.isEmpty:
				return ScriptedReply(normal)
			default:
				return unknown(text)
			}
		}

		static let partialReply = "This week has Tuesday sweet spot"

		static let savedMemory: [ScriptedEvent] = [
			.toolCall(
				name: ToolName.memoryWrite.rawValue,
				arguments:
					#"{"type":"memory","section":"schedule","content":"Rides with a group on Saturdays."}"#
			),
			.finish(reason: .toolCalls),
		]

		static let flushPartial: [ScriptedEvent] =
			[
				.toolCall(
					name: ToolName.memoryWrite.rawValue,
					arguments:
						#"{"section":"schedule","content":"Rides with a group on Saturdays."}"#),
				.toolCall(
					name: ToolName.ledgerAppend.rawValue,
					arguments:
						#"{"kind":"decision","date":"1998-06-15","text":"Keeps Saturdays for the group ride."}"#
				),
				.finish(reason: .toolCalls),
			] + Array(repeating: .fail(.http(status: 500)), count: 4)

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
