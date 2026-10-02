import EnduragentCoachFixtures
import Foundation

@testable import EnduragentCoach

struct TestWaitDeadlineExceeded: Error {}

func firstSnapshot(
	in stream: AsyncStream<ChatSnapshot>, within limit: TestWaitLimit,
	where matches: @escaping @Sendable (ChatSnapshot) -> Bool
) async throws -> ChatSnapshot? {
	try await beforeDeadline(within: limit) {
		await stream.first(where: matches)
	} ?? nil
}

func beforeDeadline<Value: Sendable>(
	within limit: TestWaitLimit, onTimeout: @escaping @Sendable () -> Void = {},
	_ event: @escaping @Sendable () async throws -> Value
) async throws -> Value? {
	try Task.checkCancellation()
	return try await withTaskCancellationHandler {
		try await withThrowingTaskGroup(of: Value?.self) { group in
			defer { group.cancelAll() }
			group.addTask { try await event() }
			group.addTask {
				try await Task.sleep(for: limit.duration)
				return nil
			}
			let found = try await group.next() ?? nil
			if found == nil { onTimeout() }
			try Task.checkCancellation()
			return found
		}
	} onCancel: {
		onTimeout()
	}
}
