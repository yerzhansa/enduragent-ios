import Foundation

extension Coach {
	public func observe(_ chat: ChatID) async -> AsyncStream<ChatSnapshot> {
		await mailbox(for: chat).observe()
	}

	func observeImports() {
		guard importObservation == nil, !lifetime.terminating else { return }
		importObservation = Task { [weak self, imports = ledger.imports] in
			for await _ in imports {
				guard !Task.isCancelled else { return }
				await self?.scheduleImportRefresh()
			}
		}
	}

	private func scheduleImportRefresh() {
		guard !lifetime.terminating else { return }
		pendingImportRefresh?.cancel()
		pendingImportRefresh = Task { [weak self] in
			do {
				try await Task.sleep(for: .milliseconds(200))
			} catch is CancellationError {
				return
			} catch {
				fatalError("Import coalescing sleep failed: \(error)")
			}
			guard !Task.isCancelled else { return }
			await self?.refreshImports()
		}
	}

	private func refreshImports() async {
		pendingImportRefresh = nil
		guard !lifetime.terminating else { return }
		for mailbox in mailboxes.values {
			do {
				try await mailbox.refreshImports()
			} catch {
				diagnostics.record(.importsUnavailable(mailbox.chatId, error))
			}
		}
	}
}
