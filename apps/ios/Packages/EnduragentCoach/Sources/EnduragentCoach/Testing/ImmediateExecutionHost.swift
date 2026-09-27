import Foundation
import Synchronization

public final class ImmediateExecutionHost: ExecutionHost {
	private let expiringAfter: Duration?
	private let state = Mutex<State>(State())

	private struct State {
		var records: [LeaseRecord] = []
		var expiries: [Int: @Sendable (ExpiryCause) async -> Void] = [:]
	}

	public init(expiringAfter: Duration? = nil) {
		self.expiringAfter = expiringAfter
	}

	public var leases: [LeaseRecord] {
		state.withLock { $0.records }
	}

	public func beginLease(
		_ request: LeaseRequest, onExpiry: @escaping @Sendable (ExpiryCause) async -> Void
	) async -> any ExecutionLease {
		let kind: LeaseKind =
			request.initiatedBy == .athlete ? .continuedProcessing : .gracePeriodOnly
		let index = state.withLock { current in
			let index = current.records.count
			current.records.append(
				LeaseRecord(id: "lease-\(index + 1)", request: request, kind: kind))
			current.expiries[index] = onExpiry
			return index
		}
		if let expiringAfter {
			Task {
				do {
					try await Task.sleep(for: expiringAfter)
				} catch is CancellationError {
					return
				} catch {
					fatalError("Task.sleep failed: \(error)")
				}
				await self.expire(index, .systemExpired)
			}
		}
		return Lease(host: self, index: index, kind: kind)
	}

	public func expire(_ cause: ExpiryCause) async {
		let open = state.withLock { current in current.expiries.keys.sorted() }
		for index in open {
			await expire(index, cause)
		}
	}

	public func ended(_ index: Int, within limit: Duration = .seconds(5)) async -> LeaseRecord? {
		let deadline = ContinuousClock.now + limit
		while ContinuousClock.now < deadline {
			let record = state.withLock { current in
				current.records.indices.contains(index) ? current.records[index] : nil
			}
			if let record, record.ending != nil {
				return record
			}
			do {
				try await Task.sleep(for: .milliseconds(10))
			} catch is CancellationError {
				return nil
			} catch {
				fatalError("Task.sleep failed: \(error)")
			}
		}
		return nil
	}

	private func expire(_ index: Int, _ cause: ExpiryCause) async {
		let handler = state.withLock { current in
			let handler = current.expiries.removeValue(forKey: index)
			if handler != nil {
				current.records[index].expiry = cause
			}
			return handler
		}
		await handler?(cause)
	}

	fileprivate func update(_ index: Int, _ change: (inout LeaseRecord) -> Void) {
		state.withLock { current in
			change(&current.records[index])
			if current.records[index].ending != nil {
				current.expiries[index] = nil
			}
		}
	}
}

private struct Lease: ExecutionLease {
	let host: ImmediateExecutionHost
	let index: Int
	let kind: LeaseKind

	func report(_ progress: LeaseProgress) async {
		host.update(index) { $0.progress = progress }
	}

	func end(_ ending: LeaseEnding) async {
		host.update(index) { $0.ending = ending }
	}
}
