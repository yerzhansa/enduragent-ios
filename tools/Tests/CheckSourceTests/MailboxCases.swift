extension SourceCases {
	static let mailbox =
		"apps/ios/Packages/EnduragentCoach/Sources/EnduragentCoach/Chat/ChatMailbox.swift"
	static let exposedState = "[mailbox-private-state]"

	private static func inMailbox(_ declaration: String) -> [String: String] {
		[mailbox: "package actor ChatMailbox {\n\(declaration)\n}"]
	}

	static let mailboxState: [SourceCase] =
		[
			"var runner: TurnRunner",
			"let renamed: Ledger",
			"private(set) var runner: TurnRunner",
			"fileprivate let runner: TurnRunner",
			"public nonisolated let renamed: Clock",
			"package(set) var state: State",
			"@ObservationIgnored public private(set) lazy var state = State()",
			"package var chatId: ChatID",
			"package let (a, b) = (1, 2)",
			"var `default`: TurnRunner",
			"lazy var state = State()",
			"lazy var state: State = { State() }()",
			"var state = makeState { State() }",
			"var state: State { willSet { record(newValue) } }",
			"var state: State { didSet { record(oldValue) } }",
			"var state = State() { didSet { record(oldValue) } }",
			"var exposed: State { get { state } set { state = newValue } }",
			"private(set) var exposed: State { get { state } set(value) { state = value } }",
			"var exposed: State { _read { yield state } _modify { yield &state } }",
			"var exposed: State { get { state } nonmutating set { replace(newValue) } }",
			"var exposed: State { get { state } @_transparent set { state = newValue } }",
			"var exposed: State { _read { yield state } @_transparent _modify { yield &state } }",
			"var exposed: State\n{\nget { state }\nset\n{ state = newValue }\n}",
		].map { declaration in
			.rejects(
				"rejects exposed mailbox state: \(declaration)", inMailbox(declaration),
				finding: exposedState)
		}
		+ [
			("same-line member", "package actor ChatMailbox { var runner: TurnRunner }"),
			(
				"member after a method",
				"package actor ChatMailbox { func accept() {} ; var runner: TurnRunner }"
			),
			(
				"member after private state",
				"package actor ChatMailbox { private let hidden = 1; var runner: TurnRunner }"
			),
			(
				"opening brace in a multiline string",
				"package actor ChatMailbox {\nprivate let text = \"\"\"\n{\n\"\"\"\nvar runner: TurnRunner\n}"
			),
			(
				"closing brace in a multiline string",
				"package actor ChatMailbox {\nprivate let text = \"\"\"\n}\n\"\"\"\nvar runner: TurnRunner\n}"
			),
			(
				"braces and quotes in a raw multiline string",
				"package actor ChatMailbox {\nprivate let text = #\"\"\"\n\"{\"\n\"\"\"#\nvar runner: TurnRunner\n}"
			),
		].map { name, source in
			.rejects(
				"rejects exposed mailbox state with \(name)", [mailbox: source],
				finding: exposedState)
		}
		+ [
			.accepts(
				"accepts inline private mailbox bindings and braces inside strings",
				[
					mailbox: #"""
					package actor ChatMailbox { package let chatId: ChatID;
					    private let (a, b) = (1, 2); private var `default`: TurnRunner
					    private let text = """
					    } var exposed: TurnRunner {
					    """
					    package func accept() { let runner = self.runner }
					  }
					"""#
				])
		]
		+ [
			"var exposed: State { state }",
			"package var runningScope: TurnScope? { work.phase.running?.attempt?.scope }",
			"var exposed: State { get { state } }",
			"var exposed: State { _read { yield state } }",
			"var exposed: State\n{\nstate\n}",
			"var exposed: State { let copy = state; return copy }",
			"var exposed: State { let set = state; return set }",
			#"var exposed: String { "set { _modify { didSet {" }"#,
			"var exposed: State { get async throws { try await load() } }",
			"package func queue() -> State { state }",
		].map { declaration in
			.accepts(
				"accepts read-only mailbox projections: \(declaration)", inMailbox(declaration))
		}
		+ [
			.accepts(
				"accepts private mailbox state, its immutable identity, and method locals",
				[
					mailbox: """
					package actor ChatMailbox {
					    package let chatId: ChatID
					    private let runner: TurnRunner
					    @ObservationIgnored private lazy var state = State {
					      let local = State()
					      return local
					    }
					    nonisolated private let clock: Clock
					    package func accept() {
					      let runner = self.runner
					      if let state = state { state.run() }
					    }
					  }
					"""
				])
		]
}
