import EnduragentCoach
import EnduragentCoachFixtures
import Foundation
import Testing

@testable import Enduragent

@MainActor
final class SettlementObservingHost: ExecutionHost {
	let inner: ContinuedProcessingHost
	var coach: Coach?
	var events: [String] = []
	private(set) var settledCounts: [Int] = []

	init(inner: ContinuedProcessingHost) {
		self.inner = inner
	}

	func beginLease(
		_ request: LeaseRequest, onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease {
		SettlementObservingLease(
			inner: await inner.beginLease(request, onExpiry: onExpiry), host: self)
	}

	func recordSettlement() async {
		do {
			let coach = try #require(coach)
			let records = try await coach.recordSyncProbe().snapshot()
			settledCounts.append(records.counts.first { $0.kind == "turnSettled" }?.count ?? 0)
			var iterator = await coach.observe(.main).makeAsyncIterator()
			let snapshot = try #require(await iterator.next())
			#expect(snapshot.turns.allSatisfy { $0.state.isSettled })
			events.append("settled")
		} catch {
			Issue.record(error)
		}
	}
}

private struct SettlementObservingLease: ExecutionLease {
	let inner: any ExecutionLease
	let host: SettlementObservingHost
	var kind: LeaseKind { inner.kind }

	func report(_ progress: LeaseProgress) async {
		await inner.report(progress)
	}

	func updateTitle(_ title: CatalogKey, language: LanguageTag) async {
		await inner.updateTitle(title, language: language)
	}

	func end(_ ending: LeaseEnding) async {
		await host.recordSettlement()
		await inner.end(ending)
	}
}

actor ExpirySettlementGate {
	private(set) var started = false
	private var released = false

	func wait() async {
		started = true
		let deadline = ContinuousClock.now + TestWaitLimit.hangGuard.duration
		while !released, ContinuousClock.now < deadline {
			do {
				try await Task.sleep(for: .milliseconds(10))
			} catch {
				Issue.record(error)
				return
			}
		}
		#expect(released)
	}

	func release() {
		released = true
	}
}
