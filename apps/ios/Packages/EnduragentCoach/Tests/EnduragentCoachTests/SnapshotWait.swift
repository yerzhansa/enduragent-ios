import Foundation

@testable import EnduragentCoach

func firstSnapshot(
	in stream: AsyncStream<ChatSnapshot>, within limit: Duration,
	where matches: @escaping @Sendable (ChatSnapshot) -> Bool
) async -> ChatSnapshot? {
	await withTaskGroup(of: ChatSnapshot?.self) { group in
		group.addTask {
			for await snapshot in stream where matches(snapshot) {
				return snapshot
			}
			return nil
		}
		group.addTask {
			do {
				try await Task.sleep(for: limit)
			} catch is CancellationError {
				return nil
			} catch {
				fatalError("Task.sleep failed: \(error)")
			}
			return nil
		}
		let found = await group.next() ?? nil
		group.cancelAll()
		return found
	}
}
