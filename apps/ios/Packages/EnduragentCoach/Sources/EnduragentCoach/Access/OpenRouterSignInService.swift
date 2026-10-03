public struct OpenRouterSignInService: Sendable {
	package let authorizer: any OpenRouterAuthorizer
	package let exchange: OpenRouterKeyExchange

	public init(authorizer: any OpenRouterAuthorizer) {
		self.init(authorizer: authorizer, exchange: OpenRouterKeyExchange())
	}

	package init(authorizer: any OpenRouterAuthorizer, exchange: OpenRouterKeyExchange) {
		self.authorizer = authorizer
		self.exchange = exchange
	}
}
