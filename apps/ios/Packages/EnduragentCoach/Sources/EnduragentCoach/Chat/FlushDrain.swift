import Foundation

package struct FlushDrain: Sendable {
	private let memory: Memory
	private let transport: any ModelTransport
	private let access: @Sendable () throws(AccessUnavailable) -> ResolvedAccess
	private let diagnostics: DiagnosticsLog

	package init(
		memory: Memory,
		transport: any ModelTransport,
		access: @escaping @Sendable () throws(AccessUnavailable) -> ResolvedAccess,
		diagnostics: DiagnosticsLog
	) {
		self.memory = memory
		self.transport = transport
		self.access = access
		self.diagnostics = diagnostics
	}

	package func drain(_ chat: ChatID) async {
		do {
			try await memory.flush(
				trigger: .softThreshold, chatId: chat, transport: transport, access: try access())
		} catch is CancellationError {
		} catch {
			diagnostics.record(.memoryFlushFailed(chat, detail: String(describing: error)))
		}
	}
}
