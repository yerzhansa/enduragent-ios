import EnduragentCoach

public actor FakeOpenRouterAuthorizer: OpenRouterAuthorizer {
	public enum Response: Sendable {
		case held
		case completed(Result<OpenRouterAuthCode, SignInFailure>)
	}

	private let response: Response
	public private(set) var requests: [OpenRouterAuthRequest] = []
	private var held: [Int: AsyncStream<Result<OpenRouterAuthCode, SignInFailure>>.Continuation] =
		[:]

	public init(response: Response = .completed(.failure(.presentationUnavailable))) {
		self.response = response
	}

	public func authorize(_ request: OpenRouterAuthRequest) async throws(SignInFailure)
		-> OpenRouterAuthCode
	{
		let index = requests.count
		requests.append(request)
		switch response {
		case .completed(let result):
			return try result.get()
		case .held:
			let (results, completion) = AsyncStream<Result<OpenRouterAuthCode, SignInFailure>>
				.makeStream(
					bufferingPolicy: .bufferingNewest(1))
			held[index] = completion
			defer { held.removeValue(forKey: index) }
			guard let result = await results.first(where: { _ in true }) else {
				throw .canceled
			}
			return try result.get()
		}
	}

	public func complete(_ result: Result<OpenRouterAuthCode, SignInFailure>, at index: Int) {
		guard let completion = held.removeValue(forKey: index) else { return }
		completion.yield(result)
		completion.finish()
	}
}
