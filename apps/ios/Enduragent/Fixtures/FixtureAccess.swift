#if DEBUG
	import EnduragentCoach
	import EnduragentCoachFixtures

	extension FirstWeekFixture {
		static let openRouterKey = "fixture-openrouter-key"
		static let openRouterModel = ModelID(rawValue: "fixture/openrouter-model")

		static func install(_ method: FixtureAccessMethod, on secrets: ICloudKeychainStore) throws {
			switch method {
			case .credits, .openRouter:
				try install(on: secrets)
			case .creditsNeedsSetup, .openRouterNeedsCredits:
				_ = try secrets.prepareCreditsAccount()
			}
			if method == .openRouter || method == .openRouterNeedsCredits {
				try secrets.installOpenRouterChoice(model: openRouterModel, key: openRouterKey)
			}
		}

		static func install(_ outcome: FixtureCreditsOutcome, on credits: FakeCreditsClient) {
			switch outcome {
			case .ready: break
			case .zero:
				credits.grantResult = .success(.minted(Credits(units: 0)))
				credits.balanceResult = .success(CreditBalance(credits: Credits(units: 0)))
			case .unavailable:
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
