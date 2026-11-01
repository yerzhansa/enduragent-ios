import Foundation

package struct ReviewPreparingBody: Sendable, Equatable {
	package let chatId: ChatID
	package let turn: TurnID
	package let attempt: AttemptID
}
