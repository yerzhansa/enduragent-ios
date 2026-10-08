import EnduragentCoach
import EnduragentCoachFixtures
import Security
import Testing

@testable import Enduragent

@MainActor
@Suite(.serialized, FixtureTestScope())
struct ModelPickerTests {
	private let harness = FixtureLaunchTests()
	private let refreshed = ModelID(rawValue: "fixture/refreshed-model")

	@Test func sameProviderChoiceUpdatesObservedRowsAndSurvivesRelaunch() async throws {
		do {
			let model = try await open()
			let before = try #require(model.modelChoices?.selected)
			#expect(before.id == AppServices.builtInModel)
			#expect(model.modelPickerEntries.contains { $0.id == refreshed })
			model.open(.settings)
			model.open(.modelPicker)
			await model.chooseModel(refreshed)
			try await model.waitForStatus { $0.access.model == refreshed }
			#expect(model.modelChoices?.selected.details.displayName == "Refreshed Coach")
			#expect(model.navigation == [.settings, .modelPicker])
			#expect(model.accessNotice == nil)
			#expect(!model.isChangingAccess)
		}
		let reopened = try await reopen()
		#expect(reopened.modelChoices?.selected.id == refreshed)
		#expect(reopened.modelChoices?.selected.details.displayName == "Refreshed Coach")
		#expect(reopened.modelPickerEntries.contains { $0.id == refreshed })
		#expect(reopened.route == .chat)
	}

	@Test(arguments: [false, true])
	func leavingAndFailedWritesKeepTheSavedChoice(writeFails: Bool) async throws {
		let previous: ModelCatalogEntry
		do {
			let model = try await open()
			previous = try #require(model.modelChoices?.selected)
			model.draft.text = TutorialCopy.weekQuestion
			model.open(.settings)
			model.open(.modelPicker)
			if writeFails {
				let backing = try #require(model.services.fixture?.secretBacking)
				backing.failWrites(
					CredentialSlot.accessSelection.rawValue, with: errSecNotAvailable)
				await model.chooseModel(refreshed)
				#expect(model.accessNotice?.key == Catalog.reviewSaveFailed)
				#expect(
					model.accessNotice?.sentence(in: model.displayLocale)
						== "Couldn't save your choice on this iPhone, so nothing was changed. Try again."
				)
			}
			model.navigation.removeAll()
			#expect(model.modelChoices?.selected == previous)
			#expect(model.route == .chat)
			#expect(model.draft.text == TutorialCopy.weekQuestion)
		}
		let reopened = try await reopen()
		#expect(reopened.modelChoices?.selected == previous)
	}

	@Test(arguments: ["accept", "decline", "failed-write"])
	func providerChoiceUsesTheExistingConsentRoute(decision: String) async throws {
		let model = try await open()
		let fixture = try #require(model.services.fixture)
		let previous = try #require(model.modelChoices?.selected)
		let another = try #require(ModelCatalog.bundled.orderedEntries.last)
		model.open(.settings)
		model.open(.modelPicker)
		await model.chooseModel(another.id)
		try await model.waitForStatus { $0.needsProviderConsent }
		#expect(model.route == .onboarding(.consent))
		#expect(model.modelChoices?.selected == previous)
		#expect(model.consentChallenge?.target.entry == another)
		#expect(fixture.transport.requestCount == 0)
		switch decision {
		case "decline":
			await model.declineConsent()
			try await model.waitForStatus { !$0.needsProviderConsent }
			#expect(model.route == .chat)
			#expect(model.modelChoices?.selected == previous)
		case "failed-write":
			try #require(fixture.secretBacking).failWrites(
				CredentialSlot.accessSelection.rawValue, with: errSecNotAvailable)
			await model.acceptConsent()
			#expect(model.consentNotSaved)
			#expect(model.consentFailureKey == Catalog.reviewSaveFailed)
			#expect(model.modelChoices?.selected == previous)
			#expect(model.route == .onboarding(.consent))
			await model.declineConsent()
			try await model.waitForStatus { !$0.needsProviderConsent }
			#expect(model.route == .chat)
			#expect(model.modelChoices?.selected == previous)
		default:
			await model.acceptConsent()
			try await model.waitForStatus { $0.access.model == another.id }
			#expect(model.modelChoices?.selected == another)
			#expect(model.route == .chat)
		}
		#expect(fixture.transport.requestCount == 0)
	}

	private func open() async throws -> ShellModel {
		var launch = harness.launch
		launch.accessMethod = .catalogOpenRouter
		launch.catalogResponse = .newer
		let services = try fixtureServices(launch, defaults: harness.defaults, language: .en)
		let model = await harness.model(services)
		await model.agreeAndStartChatting()
		await model.sceneChanged(.becameActive)
		try await model.waitForStatus {
			$0.access.modelChoices?.catalog.cache == .available(.downloaded)
		}
		try await harness.observed(model)
		return model
	}

	private func reopen() async throws -> ShellModel {
		let (services, defaults) = try await harness.relaunch(.keep, language: .en)
		let model = await fixtureModel(
			environment: AppEnvironment(services: services, defaults: defaults))
		try await harness.observed(model)
		return model
	}
}
