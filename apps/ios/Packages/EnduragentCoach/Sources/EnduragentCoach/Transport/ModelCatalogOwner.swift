import Foundation
import Synchronization

package actor ModelCatalogOwner {
	private nonisolated let status: Mutex<ModelCatalogStatus>
	package nonisolated let bundled: ModelCatalog
	private let source: (any ModelCatalogSource)?
	private let cache: (any ModelCatalogCache)?
	private var refreshTask: Task<Void, Never>?
	package nonisolated let updates: AsyncStream<Void>
	private let update: AsyncStream<Void>.Continuation

	package init(
		bundled: ModelCatalog = .bundled, source: (any ModelCatalogSource)? = nil,
		cache: (any ModelCatalogCache)? = nil
	) {
		self.bundled = bundled
		self.source = source
		self.cache = cache
		(updates, update) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
		var initial = ModelCatalogStatus(catalog: bundled, cache: .available(.bundled))
		do {
			if let saved = try cache?.load() {
				if saved.revision > bundled.revision {
					initial = ModelCatalogStatus(catalog: saved, cache: .available(.downloaded))
				} else {
					initial = ModelCatalogStatus(
						catalog: bundled, cache: .retained(.bundled, .stale))
				}
			}
		} catch let issue as ModelCatalogIssue {
			initial = ModelCatalogStatus(
				catalog: bundled, cache: .retained(.bundled, issue.refreshIssue))
		} catch {
			initial = ModelCatalogStatus(
				catalog: bundled, cache: .retained(.bundled, .storageUnavailable))
		}
		status = Mutex(initial)
	}

	package nonisolated func snapshot() -> ModelCatalogStatus {
		status.withLock { $0 }
	}

	package func refresh() {
		guard refreshTask == nil, let source, let cache else { return }
		let origin = snapshot().cache.origin
		publish(ModelCatalogStatus(catalog: snapshot().catalog, cache: .refreshing(origin)))
		refreshTask = Task { await download(from: source, into: cache, origin: origin) }
	}

	package func cancelRefresh() {
		refreshTask?.cancel()
	}

	private func download(
		from source: any ModelCatalogSource, into cache: any ModelCatalogCache,
		origin: CatalogOrigin
	) async {
		defer { refreshTask = nil }
		do {
			let data = try await source.download()
			try Task.checkCancellation()
			let catalog = try ModelCatalog(validating: data)
			guard catalog.revision > snapshot().catalog.revision else { throw CatalogIssue.stale }
			do {
				try cache.replaceAtomically(catalog)
			} catch {
				throw CatalogIssue.storageUnavailable
			}
			publish(ModelCatalogStatus(catalog: catalog, cache: .available(.downloaded)))
		} catch is CancellationError {
			publish(ModelCatalogStatus(catalog: snapshot().catalog, cache: .available(origin)))
		} catch let issue as CatalogIssue {
			retain(origin, issue)
		} catch let issue as ModelCatalogIssue {
			retain(origin, issue.refreshIssue)
		} catch {
			retain(origin, .offline)
		}
	}

	private func retain(_ origin: CatalogOrigin, _ issue: CatalogIssue) {
		publish(ModelCatalogStatus(catalog: snapshot().catalog, cache: .retained(origin, issue)))
	}

	private func publish(_ snapshot: ModelCatalogStatus) {
		status.withLock { $0 = snapshot }
		update.yield()
	}
}

extension ModelCatalogIssue {
	var refreshIssue: CatalogIssue {
		switch self {
		case .noUsableChoices: .noUsableChoices
		case .malformed, .modelNotInCatalog: .malformed
		}
	}
}

extension CatalogCacheState {
	var origin: CatalogOrigin {
		switch self {
		case .available(let origin), .refreshing(let origin), .retained(let origin, _): origin
		}
	}
}
