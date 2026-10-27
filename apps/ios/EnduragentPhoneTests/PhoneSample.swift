#if !targetEnvironment(simulator)
	import XCTest

	struct PhoneRunBlocked: Error {
		let reason: String
	}

	struct PhoneNode: Sendable {
		let identifier: String
		let label: String
		let value: String
		let type: XCUIElement.ElementType
		let inTranscript: Bool
	}

	struct PhoneSample {
		let nodes: [PhoneNode]
		let tail: [PhoneNode]
		let turns: Int
		let settled: Int

		var working: Bool { tail.contains { $0.identifier == "chat.working" } }
		var replyLines: [String] {
			tail.filter {
				$0.type == .staticText
					&& (["", "chat.transcript"].contains($0.identifier)
						|| $0.identifier.hasPrefix("reply."))
			}
			.map(\.label)
		}
		var replyLength: Int { replyLines.map(\.count).reduce(0, +) }
		func has(_ identifier: String) -> Bool { nodes.contains { $0.identifier == identifier } }

		@MainActor
		init(_ app: XCUIApplication, after question: String = "") throws {
			var nodes: [PhoneNode] = []
			func walk(_ snapshot: any XCUIElementSnapshot, inside: Bool) {
				if snapshot.elementType == .keyboard { return }
				let here = inside || snapshot.identifier == "chat.transcript"
				nodes.append(
					PhoneNode(
						identifier: snapshot.identifier, label: snapshot.label,
						value: snapshot.value as? String ?? "", type: snapshot.elementType,
						inTranscript: here))
				for child in snapshot.children { walk(child, inside: here) }
			}
			walk(try app.snapshot(), inside: false)
			guard let progress = nodes.first(where: { $0.identifier == "chat.turnProgress" }) else {
				throw PhoneRunBlocked(
					reason: "No turn progress on screen. The operator must open the conversation.")
			}
			let fields = progress.value.split(separator: " ")
			guard fields.count == 4, let turns = Int(fields[1]), let settled = Int(fields[3]) else {
				throw PhoneRunBlocked(reason: "Unreadable turn progress.")
			}
			let transcript = nodes.filter(\.inTranscript)
			let index = transcript.lastIndex { $0.type == .staticText && $0.label == question }
			self.nodes = nodes
			self.tail = index.map { Array(transcript[($0 + 1)...]) } ?? []
			self.turns = turns
			self.settled = settled
		}
	}
#endif
