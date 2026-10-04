#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures

	extension FixtureSignInOutcome {
		var response: FakeOpenRouterAuthorizer.Response {
			switch self {
			case .success, .exchangeFailure:
				.completed(.success(OpenRouterAuthCode(code: "fixture-code")))
			case .cancel: .completed(.failure(.canceled))
			case .rejectedCallback: .completed(.failure(.callbackRejected))
			case .held: .held
			}
		}
	}

	extension FirstWeekFixture {
		static let openRouterKey = "fixture-openrouter-key"
		static let openRouterModel = ModelID(rawValue: "fixture/openrouter-model")

		static func install(_ method: FixtureAccessMethod, on secrets: ICloudKeychainStore) throws {
			switch method {
			case .credits, .openRouter, .syncedOpenRouter, .missingOpenRouter, .rejectedOpenRouter:
				try install(on: secrets)
			case .creditsNeedsSetup, .openRouterNeedsCredits:
				_ = try secrets.prepareCreditsAccount()
			}
			try secrets.storeOpenRouterAccountKey(openRouterKey, at: .legacy)
			if method == .syncedOpenRouter {
				guard let entry = ModelCatalog.bundled.orderedEntries.last else {
					throw FixtureLaunchError.unknownArgument(
						key: FixtureLaunch.accessArgumentKey, value: method.rawValue)
				}
				try secrets.installOpenRouterChoice(
					model: entry.id, key: openRouterKey, catalog: .bundled)
			}
			if [.openRouter, .openRouterNeedsCredits, .missingOpenRouter, .rejectedOpenRouter]
				.contains(method)
			{
				try secrets.installOpenRouterChoice(model: openRouterModel, key: openRouterKey)
			}
			if method == .missingOpenRouter { try secrets.deleteOpenRouterAccountKey(at: .legacy) }
		}

		static func install(_ outcome: FixtureCreditsOutcome, on credits: FakeCreditsClient) {
			switch outcome {
			case .ready: break
			case .zero:
				credits.grantResult = .success(.minted(Credits(units: 0)))
				credits.balanceResult = .success(CreditBalance(credits: Credits(units: 0)))
			case .unavailable:
				credits.grantResult = .failure(.unavailable)
				credits.balanceResult = .failure(.unavailable)
			case .provisioningFailed:
				credits.grantResult = .failure(.unavailable)
				credits.balanceResult = .failure(.noAthleteKey)
			case .alreadyGranted:
				credits.grantResult = .success(.alreadyGranted)
			}
		}
	}
#endif
